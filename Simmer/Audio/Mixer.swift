import AppKit
import CoreAudio
import Observation

/// One row in the menu: an app that is making sound.
struct MixerApp: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    /// 0 to 1, where 1 means "as loud as the app makes it".
    var volume: Float
    var isMuted: Bool
    var isPlaying: Bool

    static func == (a: MixerApp, b: MixerApp) -> Bool {
        a.id == b.id && a.name == b.name && a.volume == b.volume
            && a.isMuted == b.isMuted && a.isPlaying == b.isPlaying
    }
}

/// Keeps the list of apps that make sound, remembers each app's volume,
/// and adds or removes taps to match.
@MainActor
@Observable
final class Mixer {
    /// Apps shown in the menu, sorted by name so rows do not jump around.
    private(set) var apps: [MixerApp] = []
    private(set) var permission: AudioPermission.Status = AudioPermission.status
    private(set) var outputName = ""
    /// The last error Simmer hit while changing a volume, shown in the menu.
    private(set) var problem: String?

    @ObservationIgnored private var sources: [String: SoundSource] = [:]
    @ObservationIgnored private var lastHeard: [String: Date] = [:]
    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var failed: [String: [AudioObjectID]] = [:]
    @ObservationIgnored private var outputUID = ""
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isAsking = false
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var lastPlaying: [String] = []

    /// How long an app stays in the list after it goes quiet.
    private let linger: TimeInterval = 8

    // Saved settings, keyed by bundle ID.
    @ObservationIgnored private var volumes: [String: Float] {
        get { UserDefaults.standard.dictionary(forKey: "volumes") as? [String: Float] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "volumes") }
    }
    @ObservationIgnored private var muted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "muted") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "muted") }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Puts every app's sound back to normal. Called when Simmer quits.
    func stopAll() {
        timer?.invalidate()
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }

    // MARK: - Changes from the menu

    func setVolume(_ volume: Float, for key: String) {
        let clamped = min(max(volume, 0), 1)
        var saved = volumes
        saved[key] = clamped == 1 ? nil : clamped
        volumes = saved
        if clamped > 0, muted.contains(key) { muted.remove(key) }
        update(key)
    }

    func toggleMute(_ key: String) {
        if muted.contains(key) {
            muted.remove(key)
            if (volumes[key] ?? 1) == 0 { setVolume(1, for: key); return }
        } else {
            muted.insert(key)
        }
        Log.shared.add("\(sources[key]?.name ?? key) \(muted.contains(key) ? "muted" : "unmuted")")
        update(key)
    }

    /// Every app back to full volume, none muted.
    func resetAll() {
        volumes = [:]
        muted = []
        failed.removeAll()
        Log.shared.add("Reset every app to full volume")
        reconcileAll()
        publish()
    }

    var hasChanges: Bool { !volumes.isEmpty || !muted.isEmpty }

    func askForPermission() {
        guard !isAsking else { return }
        isAsking = true
        Log.shared.add("Asking for permission to hear other apps")
        AudioPermission.ask { [weak self] granted in
            guard let self else { return }
            isAsking = false
            permission = AudioPermission.status
            if granted { permission = .granted }
            Log.shared.add("Permission \(granted ? "granted" : "not granted")")
            reconcileAll()
        }
    }

    private func update(_ key: String) {
        failed[key] = nil
        reconcile(key)
        publish()
    }

    // MARK: - The loop

    private func refresh() {
        let current = AudioProcesses.current()
        let now = Date()
        var next: [String: SoundSource] = [:]
        for source in current {
            next[source.key] = source
            if source.isPlaying { lastHeard[source.key] = now }
        }
        let playing = current.filter(\.isPlaying).map(\.name).sorted()
        if playing != lastPlaying {
            lastPlaying = playing
            Log.shared.add(playing.isEmpty ? "Nothing is playing" : "Playing: \(playing.joined(separator: ", "))")
        }
        let gone = Set(sources.keys).subtracting(next.keys)
        sources = next
        for key in gone {
            taps.removeValue(forKey: key)?.stop()
            lastHeard[key] = nil
            failed[key] = nil
        }

        let newPermission = AudioPermission.status
        if newPermission != permission {
            permission = newPermission
            Log.shared.add("Permission is now \(newPermission)")
        }

        // A new speaker or headphones: every tap must move to it.
        if let device = try? CoreAudio.defaultOutputDevice(), let uid = try? CoreAudio.deviceUID(device),
           uid != outputUID {
            if !outputUID.isEmpty { Log.shared.add("Sound output changed to \(CoreAudio.deviceName(device))") }
            outputUID = uid
            outputName = CoreAudio.deviceName(device)
            for tap in taps.values { tap.stop() }
            taps.removeAll()
            failed.removeAll()
        }

        reconcileAll()
        publish()
    }

    private func reconcileAll() {
        let keys = Set(sources.keys).union(taps.keys)
        for key in keys { reconcile(key) }
    }

    /// The volume the app should play at, after the loudness curve.
    /// People hear loudness on a curve, so half way on the slider is
    /// about a quarter of the signal.
    private func gain(for key: String) -> Float {
        if muted.contains(key) { return 0 }
        let volume = volumes[key] ?? 1
        return volume * volume
    }

    /// Makes the tap for one app match its setting.
    private func reconcile(_ key: String) {
        let target = gain(for: key)
        guard let source = sources[key], target < 1 else {
            if let tap = taps.removeValue(forKey: key) {
                tap.stop()
                Log.shared.add("\(sources[key]?.name ?? key) back to full volume")
            }
            return
        }

        if let tap = taps[key], tap.processObjects == source.processObjects, tap.outputUID == outputUID {
            tap.gain.value = target
            return
        }

        // Without permission, a tap would silence the app. Never do that.
        guard permission == .granted else {
            if permission == .unknown { askForPermission() }
            return
        }
        guard !outputUID.isEmpty, failed[key] != source.processObjects else { return }

        taps.removeValue(forKey: key)?.stop()
        do {
            taps[key] = try AppTap(name: source.name, processObjects: source.processObjects,
                                   outputUID: outputUID, gain: target)
            problem = nil
            Log.shared.add("Controlling \(source.name) (\(source.processObjects.count) process\(source.processObjects.count == 1 ? "" : "es"))")
        } catch {
            failed[key] = source.processObjects
            problem = "Could not change \(source.name)'s volume."
            Log.shared.add("Could not control \(source.name): \(error)")
        }
    }

    /// Updates the list the menu shows.
    private func publish() {
        let now = Date()
        let mutedSet = muted
        let saved = volumes
        let shown = sources.values.filter { source in
            // Apps Simmer is turning down stay listed, so you can turn them back up.
            if source.isPlaying || taps[source.key] != nil { return true }
            return now.timeIntervalSince(lastHeard[source.key] ?? .distantPast) < linger
        }
        let next = shown
            .map { source in
                MixerApp(id: source.key, name: source.name, icon: icon(for: source),
                         volume: saved[source.key] ?? 1, isMuted: mutedSet.contains(source.key),
                         isPlaying: source.isPlaying)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if next != apps { apps = next }
    }

    private func icon(for source: SoundSource) -> NSImage {
        if let cached = icons[source.key] { return cached }
        let image: NSImage
        if let url = source.bundleURL {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        icons[source.key] = image
        return image
    }
}
