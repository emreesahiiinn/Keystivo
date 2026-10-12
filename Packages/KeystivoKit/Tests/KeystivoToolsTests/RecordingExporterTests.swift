import AVFoundation
import Foundation
import ImageIO
@testable import KeystivoTools
import Testing

@Suite("Recording export")
struct RecordingExporterTests {
    /// Writes a one-second, 10 fps H.264 movie of changing colors.
    private func makeMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keystivo-test-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 25), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func exportsLoopingGIF() async throws {
        let movie = try await makeMovie()
        let gif = try await RecordingExporter.export(movie, as: .gif, gifFrameRate: 10)
        defer { try? FileManager.default.removeItem(at: gif) }
        #expect(gif.pathExtension == "gif")
        #expect(!FileManager.default.fileExists(atPath: movie.path))
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) >= 8)
    }

    @Test func remuxesToMP4() async throws {
        let movie = try await makeMovie()
        let mp4 = try await RecordingExporter.export(movie, as: .mp4)
        defer { try? FileManager.default.removeItem(at: mp4) }
        #expect(mp4.pathExtension == "mp4")
        let duration = try await AVURLAsset(url: mp4).load(.duration).seconds
        #expect(duration > 0.8)
    }
}
