import CoreAudio
@testable import KeystivoAudio
import Testing

@Suite("Per-app audio")
struct AudioTests {
    @Test func defaultSettingsNeedNoTap() {
        #expect(AppAudioSetting().isDefault)
        #expect(!AppAudioSetting(volume: 0.5).isDefault)
        #expect(!AppAudioSetting(muted: true).isDefault)
        #expect(AppAudioSetting(volume: 0.8, muted: true).effectiveGain == 0)
        #expect(AppAudioSetting(volume: 0.8).effectiveGain == 0.8)
    }

    @Test func levelsExchangePeaks() {
        let levels = TapLevels()
        levels.target = 0.5
        #expect(levels.target == 0.5)
        levels.reportPeak(0.3)
        levels.reportPeak(0.7)
        levels.reportPeak(0.2)
        #expect(levels.takePeak() == 0.7)
        #expect(levels.takePeak() == 0)
    }

    /// Runs the real-time renderer over interleaved stereo buffers.
    private func render(input samples: [Float], gain: Float, startGain: Float, outputChannels: Int = 2) -> ([Float], Float) {
        let frames = samples.count / 2
        let levels = TapLevels()
        levels.target = gain
        let state = TapRenderState(inputBufferOffset: 0)
        state.currentGain = startGain
        var input = samples
        var output = [Float](repeating: 99, count: frames * outputChannels)
        input.withUnsafeMutableBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(outputChannels), mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                TapRenderer.render(input: &inList, output: &outList, levels: levels, state: state)
            }
        }
        return (output, levels.takePeak())
    }

    @Test func appliesGainAndClips() {
        let (output, peak) = render(input: [0.5, -0.5, 0.9, -0.9], gain: 2, startGain: 2)
        #expect(output == [1, -1, 1, -1])
        #expect(peak == 1)
    }

    @Test func rampsBetweenGainsWithoutJumps() {
        let input = [Float](repeating: 1, count: 16)
        let (output, _) = render(input: input, gain: 0, startGain: 1)
        let left = stride(from: 0, to: output.count, by: 2).map { output[$0] }
        #expect(left.first == 1)
        #expect(zip(left, left.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(left.last! < 0.2)
    }

    @Test func extraOutputChannelsAreSilenced() {
        let (output, _) = render(input: [0.25, 0.5], gain: 1, startGain: 1, outputChannels: 4)
        #expect(output == [0.25, 0.5, 0, 0])
    }

    @Test func profileCodableRoundTrip() throws {
        var profile = AudioProfile(name: "Calls")
        profile.outputVolume = 0.4
        profile.appSettings = ["com.spotify.client": AppAudioSetting(volume: 0.2)]
        let decoded = try JSONDecoder().decode(AudioProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
    }
}
