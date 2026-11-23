import CoreAudio
import Foundation

/// A Core Audio call that failed, with its status code.
struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let what: String

    var description: String {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "\(what) failed ('\(String(decoding: bytes, as: UTF8.self))')"
        }
        return "\(what) failed (\(status))"
    }
}

/// Small helpers for reading Core Audio properties.
enum CoreAudio {
    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, what: what) }
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size value, such as a UInt32 or a pid_t.
    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result), "Reading a property")
        return result
    }

    /// Reads a list of object IDs, such as all the processes that use sound.
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Reading a list size")
        let stride = MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / stride)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids), "Reading a list")
        return Array(ids.prefix(Int(size) / stride))
    }

    /// Reads a text property. Core Audio hands back a string we own.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result), "Reading text")
        return result?.takeRetainedValue() as String? ?? ""
    }

    /// The device the Mac plays sound through right now.
    static func defaultOutputDevice() throws -> AudioDeviceID {
        try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                  initial: AudioDeviceID(kAudioObjectUnknown))
    }

    static func deviceUID(_ device: AudioDeviceID) throws -> String {
        try string(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioDeviceID) -> String {
        (try? string(device, kAudioObjectPropertyName)) ?? "Unknown device"
    }
}
