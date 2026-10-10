import AppKit
import KeystivoCore
import Vision

/// Results of analysing a captured screen region.
nonisolated public struct ScreenTextResult: Sendable, Equatable {
    public var text: String
    public var barcodes: [String]
    public var image: Data?

    public var isEmpty: Bool { text.isEmpty && barcodes.isEmpty }
}

nonisolated public enum CaptureMode: String, Codable, Sendable, CaseIterable {
    case area, window, screen
    public var titleKey: String { "capture.mode.\(rawValue)" }

    var screencaptureArguments: [String] {
        switch self {
        case .area: ["-i", "-s"]
        case .window: ["-i", "-w"]
        case .screen: ["-m"]
        }
    }
}

/// Screen capture, OCR and QR/barcode reading ("TextSniper / Shottr" features).
///
/// Uses the system `screencapture` tool for the familiar selection UI and the
/// Vision framework on-device for recognition — nothing leaves the Mac.
public enum ScreenCapture {
    public enum Failure: LocalizedError {
        case cancelled
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .cancelled: L("capture.error.cancelled")
            case .unreadable: L("capture.error.unreadable")
            }
        }
    }

    /// Lets the user pick an area/window and returns PNG data.
    public static func capture(_ mode: CaptureMode = .area) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keystivo-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = mode.screencaptureArguments + ["-x", "-o", url.path]
            try process.run()
            process.waitUntilExit()
        }.value
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw Failure.cancelled }
        return data
    }

    /// Recognizes text (any supported language, auto-detected) and barcodes.
    public static func recognize(_ data: Data, languages: [String] = []) async throws -> ScreenTextResult {
        try await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.unreadable }
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            if !languages.isEmpty { textRequest.recognitionLanguages = languages }
            let barcodeRequest = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([textRequest, barcodeRequest])
            let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let barcodes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
            return ScreenTextResult(text: joinLines(lines), barcodes: barcodes, image: data)
        }.value
    }

    /// Joins OCR lines, merging hyphenated line breaks.
    nonisolated static func joinLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            if result.hasSuffix("-"), let first = line.first, first.isLowercase {
                result.removeLast()
                result += line
            } else {
                if !result.isEmpty { result += "\n" }
                result += line
            }
        }
        return result
    }
}

// MARK: - Color picker

nonisolated public enum ColorFormat: String, Codable, Sendable, CaseIterable {
    case hex, rgb, hsl, swiftUI, nsColor
    public var titleKey: String { "color.format.\(rawValue)" }

    public func format(red: Double, green: Double, blue: Double, alpha: Double = 1) -> String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", r, g, b)
        case .rgb:
            return alpha < 1 ? "rgba(\(r), \(g), \(b), \(String(format: "%.2f", alpha)))" : "rgb(\(r), \(g), \(b))"
        case .hsl:
            let (h, s, l) = Self.hsl(red: red, green: green, blue: blue)
            return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        case .swiftUI:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", red, green, blue)
        case .nsColor:
            return String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: %.2f)", red, green, blue, alpha)
        }
    }

    static func hsl(red: Double, green: Double, blue: Double) -> (Double, Double, Double) {
        let maxValue = max(red, green, blue), minValue = min(red, green, blue)
        let lightness = (maxValue + minValue) / 2
        guard maxValue != minValue else { return (0, 0, lightness) }
        let delta = maxValue - minValue
        let saturation = lightness > 0.5 ? delta / (2 - maxValue - minValue) : delta / (maxValue + minValue)
        var hue: Double
        switch maxValue {
        case red: hue = (green - blue) / delta + (green < blue ? 6 : 0)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue *= 60
        return (hue, saturation, lightness)
    }
}

/// Picks a color anywhere on screen with the system magnifier ("Sip / ColorSlurp").
public enum ColorPicker {
    public static func pick() async -> NSColor? {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { color in
                continuation.resume(returning: color)
            }
        }
    }

    public static func string(for color: NSColor, format: ColorFormat) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return format.format(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent), alpha: Double(rgb.alphaComponent))
    }
}
