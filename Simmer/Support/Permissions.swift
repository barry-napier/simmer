import AppKit
import Foundation

/// The permission to hear other apps' sound ("System Audio Recording Only"
/// in System Settings). Simmer needs it before it can change any volume.
///
/// If Simmer tapped an app without it, macOS would mute the app and hand
/// Simmer only silence. So Simmer checks first and never taps without it.
///
/// macOS has no public call to check this permission. This uses the same
/// private calls System Settings uses, looked up at run time. If they are
/// ever gone, Simmer assumes the permission is there and asks by tapping.
enum AudioPermission {
    enum Status: Equatable {
        case granted, denied, unknown
    }

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: PreflightFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let request: RequestFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    static var status: Status {
        guard let preflight else { return .granted }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the macOS prompt. Calls back on the main thread.
    static func ask(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let request else {
            Task { @MainActor in done(true) }
            return
        }
        request(service, nil) { granted in
            Task { @MainActor in done(granted) }
        }
    }

    @MainActor
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
