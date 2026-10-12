import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Output formats for screen recordings (Kap / CleanShot-style exports).
nonisolated public enum RecordingFormat: String, Codable, Sendable, CaseIterable {
    case mov, mp4, gif
    public var titleKey: String { "record.format.\(rawValue)" }
}

/// Converts a finished .mov to MP4 (no re-encode) or an optimized, looping GIF.
nonisolated public enum RecordingExporter {
    public enum Failure: Error { case exportFailed, noFrames }

    /// Returns the exported file (the .mov itself for `.mov`); the .mov is removed after a successful export.
    public static func export(_ movie: URL, as format: RecordingFormat, gifFrameRate: Int = 15, gifMaxWidth: CGFloat = 960) async throws -> URL {
        switch format {
        case .mov:
            return movie
        case .mp4:
            let output = movie.deletingPathExtension().appendingPathExtension("mp4")
            let asset = AVURLAsset(url: movie)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw Failure.exportFailed }
            try await session.export(to: output, as: .mp4)
            try? FileManager.default.removeItem(at: movie)
            return output
        case .gif:
            let output = movie.deletingPathExtension().appendingPathExtension("gif")
            try await makeGIF(from: movie, to: output, frameRate: gifFrameRate, maxWidth: gifMaxWidth)
            try? FileManager.default.removeItem(at: movie)
            return output
        }
    }

    static func makeGIF(from movie: URL, to output: URL, frameRate: Int, maxWidth: CGFloat) async throws {
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Failure.noFrames }
        let fps = Double(max(1, min(frameRate, 30)))
        let count = max(1, Int(duration * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw Failure.exportFailed
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties)
            added += 1
        }
        guard added > 0, CGImageDestinationFinalize(destination) else { throw Failure.noFrames }
    }
}
