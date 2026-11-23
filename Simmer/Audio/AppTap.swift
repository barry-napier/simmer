import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// The volume one app plays at, shared with the audio thread.
/// The audio thread must never wait on a lock, so this is a plain atomic.
final class SharedGain: Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float) { bits = Atomic(value.bitPattern) }

    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Only the audio thread touches this: the volume it used last, so it can
/// glide to a new volume across one buffer instead of clicking.
private final class RenderState: @unchecked Sendable {
    var current: Float
    init(_ value: Float) { current = value }
}

/// Changes the volume of one app.
///
/// macOS has no "volume per app" switch. So Simmer asks macOS for a "tap" on
/// the app's sound. The tap silences the app and hands its sound to Simmer.
/// Simmer plays it on the same speakers, louder or softer.
///
/// Pieces, in the order they are made:
///  1. A process tap on the app's processes, which mutes them.
///  2. A private "aggregate device" that joins the tap (as input) to the
///     speakers (as output). Only Simmer sees it.
///  3. An IO callback on that device: copy input to output, times the volume.
final class AppTap {
    let processObjects: [AudioObjectID]
    let outputUID: String
    let gain: SharedGain

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.barrynapier.simmer.tap", qos: .userInteractive)

    init(name: String, processObjects: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        self.gain = SharedGain(gain)
        do {
            try start(name: name)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    private func start(name: String) throws {
        // 1. The tap. Mixed down to stereo, and the app goes quiet while tapped.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "Simmer: \(name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try CoreAudio.check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the tap")

        // 2. The private device that joins the tap to the speakers.
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Simmer: \(name)",
            kAudioAggregateDeviceUIDKey: "com.barrynapier.simmer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try CoreAudio.check(
            AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID), "Creating the device")

        // 3. The callback that plays the sound back at the new volume.
        let gain = self.gain
        let state = RenderState(gain.value)
        try CoreAudio.check(
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
                Renderer.render(input: input, output: output, target: gain.value, state: state)
            }, "Adding the sound callback")
        try CoreAudio.check(AudioDeviceStart(aggregateID, procID), "Starting the device")
    }

    /// Takes everything down. The app's sound goes back to normal at once.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// The work done on the audio thread. No memory is allocated here.
private enum Renderer {
    static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        target: Float,
        state: RenderState
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // Start from silence, so channels with no input stay quiet.
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        let start = state.current
        state.current = target
        let inputChannels = channelCount(inputs)
        guard inputChannels > 0 else { return }

        for outChannel in 0..<channelCount(outputs) {
            // Stereo in, stereo out. A mono tap feeds every speaker.
            let inChannel = inputChannels == 1 ? 0 : outChannel
            guard inChannel < inputChannels,
                  let source = locate(inputs, inChannel),
                  let destination = locate(outputs, outChannel) else { continue }
            let frames = min(source.frames, destination.frames)
            guard frames > 0 else { continue }
            let step = (target - start) / Float(frames)
            var level = start
            for frame in 0..<frames {
                level += step
                destination.pointer[frame * destination.stride] = source.pointer[frame * source.stride] * level
            }
        }
    }

    private static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var count = 0
        for buffer in list { count += Int(buffer.mNumberChannels) }
        return count
    }

    /// Where one channel's samples sit: a pointer, the gap between samples
    /// (2 when left and right are interleaved), and the number of frames.
    private static func locate(
        _ list: UnsafeMutableAudioBufferListPointer, _ channel: Int
    ) -> (pointer: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
        var remaining = channel
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard let data = buffer.mData, channels > 0 else { return nil }
                let samples = data.assumingMemoryBound(to: Float.self)
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (samples + remaining, channels, frames)
            }
            remaining -= channels
        }
        return nil
    }
}
