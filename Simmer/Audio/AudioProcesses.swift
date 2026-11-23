import AppKit
import CoreAudio
import Darwin

/// One app that uses sound, with every process that plays sound for it.
/// Browsers play sound from helper processes, so one app can have several.
struct SoundSource: Equatable {
    /// The bundle ID of the app, or "pid:123" for a process with no app.
    let key: String
    let name: String
    let bundleURL: URL?
    /// The Core Audio process objects that belong to this app, sorted.
    let processObjects: [AudioObjectID]
    /// True while at least one of them is sending sound out.
    let isPlaying: Bool
}

/// Finds the apps that are using sound right now.
@MainActor
enum AudioProcesses {
    static func current() -> [SoundSource] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let objects = try? CoreAudio.objects(system, kAudioHardwarePropertyProcessObjectList) else {
            return []
        }
        let me = ProcessInfo.processInfo.processIdentifier

        struct Group {
            var name: String
            var bundleURL: URL?
            var objects: [AudioObjectID] = []
            var playing = false
        }
        var groups: [String: Group] = [:]

        for object in objects {
            guard let pid = try? CoreAudio.value(object, kAudioProcessPropertyPID, initial: pid_t(-1)),
                  pid > 0, pid != me else { continue }
            let running = (try? CoreAudio.value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            let owner = Owner.find(for: pid, audioBundleID: try? CoreAudio.string(object, kAudioProcessPropertyBundleID))
            guard owner.key != Bundle.main.bundleIdentifier else { continue }
            var group = groups[owner.key] ?? Group(name: owner.name, bundleURL: owner.bundleURL)
            group.objects.append(object)
            group.playing = group.playing || running != 0
            groups[owner.key] = group
        }

        return groups.map { key, group in
            SoundSource(key: key, name: group.name, bundleURL: group.bundleURL,
                        processObjects: group.objects.sorted(), isPlaying: group.playing)
        }
    }
}

/// Works out which app a process belongs to.
@MainActor
private enum Owner {
    struct Result {
        let key: String
        let name: String
        let bundleURL: URL?
    }

    static func find(for pid: pid_t, audioBundleID: String?) -> Result {
        // 1. The process is an app in its own right, such as Music.
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
           let result = result(for: app) {
            return result
        }
        // 2. macOS says another process is responsible for it. Safari's sound
        //    comes from a WebKit process that Safari is responsible for.
        if let parent = responsiblePID(for: pid), parent != pid,
           let app = NSRunningApplication(processIdentifier: parent), let result = result(for: app) {
            return result
        }
        // 3. It lives inside an app's bundle, like "Google Chrome Helper".
        if let path = executablePath(of: pid), let appURL = outermostApp(in: path) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: appURL)?.bundleIdentifier ?? "").first,
               let result = result(for: app) {
                return result
            }
            if let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier {
                let name = FileManager.default.displayName(atPath: appURL.path)
                return Result(key: id, name: name.replacingOccurrences(of: ".app", with: ""), bundleURL: appURL)
            }
        }
        // 4. Any app of its own, even one that is not in the Dock.
        if let app = NSRunningApplication(processIdentifier: pid), let result = result(for: app) {
            return result
        }
        // 5. A plain process, such as afplay in Terminal.
        let name = processName(of: pid) ?? audioBundleID ?? "Process \(pid)"
        return Result(key: audioBundleID.flatMap { $0.isEmpty ? nil : $0 } ?? "pid:\(pid)", name: name, bundleURL: nil)
    }

    private static func result(for app: NSRunningApplication) -> Result? {
        guard let id = app.bundleIdentifier else { return nil }
        return Result(key: id, name: app.localizedName ?? id, bundleURL: app.bundleURL)
    }

    /// The outermost ".app" in a path, so helpers map to their main app.
    private static func outermostApp(in path: String) -> URL? {
        guard let range = path.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// macOS tracks which app is "responsible" for each helper process. There
    /// is no public call for it, so this looks the call up and skips it if gone.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let parent = function(pid)
        return parent > 0 ? parent : nil
    }
}
