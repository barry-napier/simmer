import AppKit
import ServiceManagement
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mixer = Mixer()

    private var logWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    /// Sparkle checks GitHub for new versions. Off in debug builds, which
    /// are not signed for release.
    private let updater = SPUStandardUpdaterController(
        startingUpdater: AppDelegate.isReleaseBuild, updaterDelegate: nil, userDriverDelegate: nil)

    private static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    private static let welcomeDoneKey = "welcomeDone"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let path = Bundle.main.bundlePath
        Log.shared.add("Simmer \(version) launched from \(path)")
        if path != "/Applications/Simmer.app" {
            Log.shared.add("Warning: not running from /Applications. Use scripts/build.sh so permissions stick.")
        }
        Log.shared.add("Permission to hear other apps: \(AudioPermission.status)")

        mixer.start()

        if !UserDefaults.standard.bool(forKey: Self.welcomeDoneKey) {
            showWelcome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Every app goes back to its own volume the moment Simmer quits.
        mixer.stopAll()
    }

    // MARK: - Menu actions

    var canCheckForUpdates: Bool { Self.isReleaseBuild }

    func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.shared.add("Open at login \(on ? "on" : "off")")
        } catch {
            Log.shared.add("Could not change open at login: \(error.localizedDescription)")
        }
    }

    func showDebugLog() {
        if logWindow == nil {
            logWindow = Windows.make(
                title: "Simmer Debug Log", size: NSSize(width: 720, height: 420),
                content: DebugLogView(log: Log.shared))
        }
        Windows.present(logWindow!)
    }

    private func showWelcome() {
        let view = WelcomeView(mixer: mixer) { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.welcomeDoneKey)
            Log.shared.add("Welcome finished")
            self?.welcomeWindow?.close()
        }
        welcomeWindow = Windows.make(title: "Welcome to Simmer", size: NSSize(width: 460, height: 400), content: view)
        Windows.present(welcomeWindow!)
    }
}
