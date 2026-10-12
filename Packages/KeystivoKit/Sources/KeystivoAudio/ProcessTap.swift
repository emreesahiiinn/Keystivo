import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Lock-free gain/peak exchange between the UI and the real-time audio thread.
nonisolated final class TapLevels: Sendable {
    private let targetBits = Atomic<UInt32>(Float(1).bitPattern)
    private let peakBits = Atomic<UInt32>(0)

    var target: Float {
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Peak since last read; reading resets it.
    func takePeak() -> Float {
        Float(bitPattern: peakBits.exchange(0, ordering: .relaxed))
    }

    func reportPeak(_ value: Float) {
        let current = Float(bitPattern: peakBits.load(ordering: .relaxed))
        if value > current { peakBits.store(value.bitPattern, ordering: .relaxed) }
    }
}

/// Real-time render state touched only by the IOProc thread.
nonisolated final class TapRenderState: @unchecked Sendable {
    var currentGain: Float = 1
    let inputBufferOffset: Int
    init(inputBufferOffset: Int) { self.inputBufferOffset = inputBufferOffset }
}

/// Captures one app's audio with a Core Audio process tap (macOS 14.2+), mutes
/// its direct output, and re-plays it through a private aggregate device with
/// our own gain applied. This is how per-app volume works without a kernel
/// extension or virtual driver.
nonisolated final class ProcessTap: @unchecked Sendable {
    let bundleID: String
    let processObjectIDs: [AudioObjectID]
    let levels = TapLevels()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.keystivo.audio.tap", qos: .userInteractive)

    /// The device this tap plays to.
    let outputUID: String

    init(bundleID: String, processObjectIDs: [AudioObjectID], outputDevice: AudioDevice, gain: Float) throws {
        self.bundleID = bundleID
        self.processObjectIDs = processObjectIDs
        self.outputUID = outputDevice.uid
        levels.target = gain

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Keystivo-\(bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "AudioHardwareCreateProcessTap") }
        tapID = tap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Keystivo-\(bundleID)",
            kAudioAggregateDeviceUIDKey: "com.keystivo.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDevice.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else {
            invalidate()
            throw CoreAudioError(status: status, operation: "AudioHardwareCreateAggregateDevice")
        }
        aggregateID = aggregate

        // The aggregate's input buffers start with the output device's own input
        // streams (e.g. a headset mic); the tap's stream comes after them.
        var streamsAddress = AudioProperty.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(outputDevice.id, &streamsAddress, 0, nil, &size)
        let state = TapRenderState(inputBufferOffset: Int(size) / MemoryLayout<AudioStreamID>.size)
        state.currentGain = gain
        let levels = self.levels

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue) { _, input, _, output, _ in
            TapRenderer.render(input: input, output: output, levels: levels, state: state)
        }
        guard status == noErr else {
            invalidate()
            throw CoreAudioError(status: status, operation: "AudioDeviceCreateIOProcIDWithBlock")
        }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else {
            invalidate()
            throw CoreAudioError(status: status, operation: "AudioDeviceStart")
        }
    }

    var gain: Float {
        get { levels.target }
        set { levels.target = newValue }
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }
}

/// Allocation-free sample copy with gain ramping, for the IOProc thread.
nonisolated enum TapRenderer {
    static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, levels: TapLevels, state: TapRenderState) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let target = levels.target
        let start = state.currentGain
        var peak: Float = 0

        // Count output frames from the first output buffer.
        guard outputs.count > 0 else { return }
        let firstChannels = max(Int(outputs[0].mNumberChannels), 1)
        let frames = Int(outputs[0].mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
        guard frames > 0 else { return }
        let step = (target - start) / Float(frames)

        var outputChannel = 0
        for outIndex in 0..<outputs.count {
            let buffer = outputs[outIndex]
            guard let outData = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outStride = max(Int(buffer.mNumberChannels), 1)
            let outFrames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * outStride))
            for channel in 0..<outStride {
                if let (inData, inStride, inFrames) = inputChannel(outputChannel, in: inputs, offset: state.inputBufferOffset) {
                    let count = min(outFrames, inFrames)
                    var gain = start
                    for frame in 0..<count {
                        var sample = inData[frame * inStride] * gain
                        if sample > 1 { sample = 1 } else if sample < -1 { sample = -1 }
                        outData[frame * outStride + channel] = sample
                        let magnitude = abs(sample)
                        if magnitude > peak { peak = magnitude }
                        gain += step
                    }
                    if count < outFrames {
                        for frame in count..<outFrames { outData[frame * outStride + channel] = 0 }
                    }
                } else {
                    for frame in 0..<outFrames { outData[frame * outStride + channel] = 0 }
                }
                outputChannel += 1
            }
        }
        state.currentGain = target
        levels.reportPeak(peak)
    }

    /// Locates the n-th logical input channel across (possibly interleaved) buffers.
    @inline(__always)
    private static func inputChannel(_ index: Int, in inputs: UnsafeMutableAudioBufferListPointer, offset: Int) -> (UnsafePointer<Float>, Int, Int)? {
        var remaining = index
        var bufferIndex = offset
        while bufferIndex < inputs.count {
            let buffer = inputs[bufferIndex]
            let channels = max(Int(buffer.mNumberChannels), 1)
            if remaining < channels {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (UnsafePointer(data + remaining), channels, frames)
            }
            remaining -= channels
            bufferIndex += 1
        }
        return nil
    }
}
