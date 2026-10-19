import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Captures the audio of a set of processes, mutes their original output, and plays it back
/// through the current output device with a gain applied.
///
/// Pipeline: process tap (macOS 14.4+) -> private aggregate device (output device + tap)
/// -> IOProc that copies the tap's input buffers to the output buffers, scaled by `gain`.
final class ProcessTap {
    let processObjectIDs: Set<AudioObjectID>
    let outputDeviceUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "VolMix.ProcessTap", qos: .userInteractive)

    /// Target gain, written from the main thread and read on the audio thread.
    private let targetGainBits: Atomic<UInt32>
    /// Gain applied at the end of the previous buffer; only touched on the audio thread.
    private var currentGain: Float

    init(name: String, processObjectIDs: Set<AudioObjectID>, outputDeviceUID: String, gain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.targetGainBits = Atomic(gain.bitPattern)
        self.currentGain = gain

        do {
            try start(name: name)
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    var gain: Float {
        get { Float(bitPattern: targetGainBits.load(ordering: .relaxed)) }
        set { targetGainBits.store(max(0, newValue).bitPattern, ordering: .relaxed) }
    }

    private func start(name: String) throws {
        // 1. Tap the processes and silence their normal output.
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs.sorted())
        description.uuid = UUID()
        description.name = "VolMix – \(name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap for \(name)")

        // 2. Wrap the tap and the real output device in a private aggregate device.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolMix – \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "Creating aggregate device for \(name)")

        // 3. Copy tap input to device output with the gain applied.
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }, "Creating IOProc for \(name)")
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting aggregate device for \(name)")
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Real-time rendering (no allocation, no locks)

    private struct Channel {
        let samples: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    private static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var count = 0
        for buffer in list { count += Int(buffer.mNumberChannels) }
        return count
    }

    /// Locates channel `index` across the buffers of a (possibly interleaved) Float32 buffer list.
    private static func channel(_ index: Int, in list: UnsafeMutableAudioBufferListPointer) -> Channel? {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard let data = buffer.mData, channels > 0 else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return Channel(samples: data.assumingMemoryBound(to: Float.self) + remaining, stride: channels, frames: frames)
            }
            remaining -= channels
        }
        return nil
    }

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // Ramp from the previous gain to the target across the buffer to avoid zipper noise.
        let startGain = currentGain
        let endGain = gain
        defer { currentGain = endGain }

        let inputChannels = Self.channelCount(inputs)
        let outputChannels = Self.channelCount(outputs)
        guard inputChannels > 0, outputChannels > 0 else { return }

        if outputChannels == 1 {
            // Mono output: average the tap's channels.
            guard let dst = Self.channel(0, in: outputs) else { return }
            let scale = 1 / Float(inputChannels)
            for c in 0..<inputChannels {
                guard let src = Self.channel(c, in: inputs) else { continue }
                Self.mix(src, into: dst, startGain: startGain * scale, endGain: endGain * scale)
            }
            return
        }

        // Tap is a stereo mixdown: send L/R to the first two output channels, leave the rest silent.
        for c in 0..<min(inputChannels, outputChannels) {
            guard let src = Self.channel(c, in: inputs), let dst = Self.channel(c, in: outputs) else { continue }
            Self.mix(src, into: dst, startGain: startGain, endGain: endGain)
        }
    }

    private static func mix(_ src: Channel, into dst: Channel, startGain: Float, endGain: Float) {
        let frames = min(src.frames, dst.frames)
        guard frames > 0 else { return }
        let step = (endGain - startGain) / Float(frames)
        var g = startGain
        for f in 0..<frames {
            dst.samples[f * dst.stride] += src.samples[f * src.stride] * g
            g += step
        }
    }
}
