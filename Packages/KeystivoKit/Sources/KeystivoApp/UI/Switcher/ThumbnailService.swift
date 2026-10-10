import AppKit
import KeystivoAccessibility
import KeystivoAudio
import KeystivoAutomation
import KeystivoClipboard
import KeystivoCore
import KeystivoFiles
import KeystivoInput
import KeystivoLinks
import KeystivoNavigation
import KeystivoPlugins
import KeystivoSearch
import KeystivoSystem
import KeystivoTools
import KeystivoWindows
import Observation
@preconcurrency import ScreenCaptureKit

/// Window thumbnails via ScreenCaptureKit, captured on demand only (when a
/// switcher or preview opens) — never continuously — and cached briefly.
@Observable
final class ThumbnailService {
    static let shared = ThumbnailService()

    private(set) var images: [CGWindowID: NSImage] = [:]
    @ObservationIgnored private var capturedAt: [CGWindowID: Date] = [:]
    @ObservationIgnored private var windowsByID: [CGWindowID: SCWindow] = [:]
    @ObservationIgnored private var contentFetchedAt: Date?
    @ObservationIgnored private var inFlight = Set<CGWindowID>()

    var isAvailable: Bool { CGPreflightScreenCaptureAccess() }

    /// Captures thumbnails for the given windows (most important first).
    func load(_ ids: [CGWindowID], width: CGFloat, maxAge: TimeInterval = 2) async {
        guard isAvailable, !ids.isEmpty else { return }
        if contentFetchedAt.map({ Date.now.timeIntervalSince($0) > 1 }) ?? true || ids.contains(where: { windowsByID[$0] == nil }) {
            await refreshShareableContent()
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let wanted = ids.filter { id in
            !inFlight.contains(id) && (capturedAt[id].map { Date.now.timeIntervalSince($0) > maxAge } ?? true)
        }
        // Capture in small batches to bound concurrent work.
        for batch in wanted.chunked(6) {
            await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
                for id in batch {
                    guard let window = windowsByID[id] else { continue }
                    inFlight.insert(id)
                    group.addTask {
                        (id, await Self.capture(window, width: width, scale: scale))
                    }
                }
                for await (id, image) in group {
                    inFlight.remove(id)
                    if let image {
                        images[id] = image
                        capturedAt[id] = .now
                    }
                }
            }
        }
    }

    private func refreshShareableContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            var map: [CGWindowID: SCWindow] = [:]
            for window in content.windows where window.windowLayer == 0 { map[window.windowID] = window }
            windowsByID = map
            contentFetchedAt = .now
        } catch {
            DiagnosticsCenter.shared.record(.warning, module: "Thumbnails", error.localizedDescription)
        }
    }

    nonisolated private static func capture(_ window: SCWindow, width: CGFloat, scale: CGFloat) async -> NSImage? {
        let frame = window.frame
        guard frame.width > 10, frame.height > 10 else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let targetWidth = min(width * scale, frame.width * scale)
        configuration.width = Int(targetWidth)
        configuration.height = Int(targetWidth * frame.height / frame.width)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    func purge() {
        images.removeAll()
        capturedAt.removeAll()
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
