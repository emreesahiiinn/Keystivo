import AVFoundation
import CoreGraphics
import Foundation
import KeystivoCore
import Observation
@preconcurrency import ScreenCaptureKit

nonisolated public struct RecordingOptions: Sendable {
    public var showsCursor = true
    public var capturesSystemAudio = false
    public var capturesMicrophone = false
    public var usesHEVC = true
    public var framesPerSecond = 60
    public var folder: URL
    /// Our own windows (recording controls, area border) that must not appear in the video.
    public var excludedWindowNumbers: [Int] = []

    public init(folder: URL) {
        self.folder = folder
    }
}

/// Screen recording to a movie file with ScreenCaptureKit's recording output.
@Observable
public final class ScreenRecorder {
    public static let shared = ScreenRecorder()

    public enum State: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case stopping
    }

    public enum Failure: LocalizedError {
        case displayNotFound
        case areaTooSmall

        public var errorDescription: String? {
            switch self {
            case .displayNotFound: L("record.error.display")
            case .areaTooSmall: L("record.error.area")
            }
        }
    }

    public private(set) var state: State = .idle
    public var isActive: Bool { state != .idle }
    /// Called with the saved movie, or the error that ended the recording.
    @ObservationIgnored public var onFinish: ((Result<URL, any Error>) -> Void)?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var recordingOutput: SCRecordingOutput?
    @ObservationIgnored private var bridge: RecorderBridge?
    @ObservationIgnored private var outputURL: URL?
    @ObservationIgnored private var finishTimeout: Task<Void, Never>?

    public init() {}

    /// Starts recording `display`, optionally limited to `area` (display-local
    /// points, top-left origin).
    public func start(display: CGDirectDisplayID, area: CGRect?, options: RecordingOptions) async throws {
        guard state == .idle else { return }
        state = .starting
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == display }) else { throw Failure.displayNotFound }
            let excluded = content.windows.filter { options.excludedWindowNumbers.contains(Int($0.windowID)) }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
            let bounds = CGRect(x: 0, y: 0, width: scDisplay.width, height: scDisplay.height)
            let source = (area ?? bounds).intersection(bounds).integral
            guard source.width >= 16, source.height >= 16 else { throw Failure.areaTooSmall }

            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            if area != nil { configuration.sourceRect = source }
            // Encoders want even dimensions.
            configuration.width = Int(source.width * scale) & ~1
            configuration.height = Int(source.height * scale) & ~1
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, options.framesPerSecond)))
            configuration.showsCursor = options.showsCursor
            configuration.queueDepth = 6
            configuration.capturesAudio = options.capturesSystemAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.captureMicrophone = options.capturesMicrophone

            try FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
            let url = options.folder.appending(path: Self.fileName(), directoryHint: .notDirectory)
            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = url
            recordingConfiguration.outputFileType = .mov
            recordingConfiguration.videoCodecType = options.usesHEVC ? .hevc : .h264

            let bridge = RecorderBridge(owner: self)
            let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: bridge)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: bridge)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()

            self.stream = stream
            self.recordingOutput = output
            self.bridge = bridge
            self.outputURL = url
            state = .recording(since: .now)
        } catch {
            reset()
            throw error
        }
    }

    public func stop() {
        guard case .recording = state, let stream else { return }
        state = .stopping
        Task { [weak self] in
            do {
                try await stream.stopCapture()
            } catch {
                self?.finish(.failure(error))
                return
            }
            // The recording output reports completion; don't wait forever for it.
            self?.finishTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self, self.state == .stopping, let url = self.outputURL else { return }
                self.finish(FileManager.default.fileExists(atPath: url.path) ? .success(url) : .failure(CocoaError(.fileNoSuchFile)))
            }
        }
    }

    fileprivate func finish(_ result: Result<URL, any Error>) {
        guard state != .idle else { return }
        finishTimeout?.cancel()
        reset()
        onFinish?(result)
    }

    fileprivate func recordingFinished() {
        guard let url = outputURL else { return }
        finish(.success(url))
    }

    fileprivate func streamStopped(with error: any Error) {
        if let url = outputURL, FileManager.default.fileExists(atPath: url.path) {
            finish(.success(url))
        } else {
            finish(.failure(error))
        }
    }

    private func reset() {
        stream = nil
        recordingOutput = nil
        bridge = nil
        outputURL = nil
        state = .idle
    }

    nonisolated static func fileName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Keystivo Recording \(formatter.string(from: date)).mov"
    }
}

/// Receives ScreenCaptureKit callbacks on its queues and forwards them to the main actor.
nonisolated private final class RecorderBridge: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private weak var owner: ScreenRecorder?

    init(owner: ScreenRecorder) {
        self.owner = owner
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in self?.owner?.streamStopped(with: error) }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in self?.owner?.recordingFinished() }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in self?.owner?.finish(.failure(error)) }
    }
}
