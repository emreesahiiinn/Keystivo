import Foundation
import SwiftUI

/// Keystivo's screen saver designs. Each becomes its own macOS screen saver
/// (`Keystivo <Name>.saver`) and is previewed live in Settings.
///
/// This module has no dependencies on the rest of Keystivo: the same sources
/// are compiled into the standalone `.saver` bundles (see Scripts/build-savers.sh).
public enum SaverStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case glass, aurora, fluid, nebula, ocean, synthwave, flip, analog, rain, minimal, shuffle

    public var id: String { rawValue }

    /// Styles that `shuffle` rotates through.
    public static let rotating: [SaverStyle] = [.glass, .aurora, .fluid, .nebula, .ocean, .synthwave, .flip, .analog, .rain, .minimal]

    /// Clock designs that can float over a see-through backdrop (the rest are
    /// full-screen artwork).
    public var supportsBackdrop: Bool {
        switch self {
        case .glass, .flip, .analog, .minimal, .shuffle: true
        default: false
        }
    }

    /// Bundle and class name fragment, e.g. "Flip" → `Keystivo Flip.saver`.
    public var bundleName: String {
        switch self {
        case .glass: "Glass"
        case .aurora: "Aurora"
        case .fluid: "Fluid"
        case .nebula: "Nebula"
        case .ocean: "Ocean"
        case .synthwave: "Synthwave"
        case .flip: "Flip"
        case .analog: "Analog"
        case .rain: "Rain"
        case .minimal: "Minimal"
        case .shuffle: "Shuffle"
        }
    }

    public var titleKey: String { "saver.style.\(rawValue)" }

    public var symbol: String {
        switch self {
        case .glass: "rectangle.on.rectangle"
        case .aurora: "sparkles"
        case .fluid: "drop.halffull"
        case .nebula: "moon.stars"
        case .ocean: "water.waves"
        case .synthwave: "sun.horizon"
        case .flip: "clock.badge"
        case .analog: "clock"
        case .rain: "chevron.left.forwardslash.chevron.right"
        case .minimal: "textformat"
        case .shuffle: "shuffle"
        }
    }

    /// How often the SwiftUI layer redraws; nil = once a second (shader
    /// backgrounds animate on the GPU by themselves).
    var frameInterval: Double? {
        switch self {
        case .flip, .analog, .fluid: 1.0 / 30
        case .glass: 1.0 / 20
        case .rain: 1.0 / 20
        case .aurora, .nebula, .ocean, .synthwave, .minimal, .shuffle: nil
        }
    }
}

/// What is behind a clock design. Only Keystivo itself can show the desktop
/// through a screen saver; macOS screen savers always use the design's own.
public enum SaverBackdrop: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The design's own background.
    case design
    /// The desktop and windows stay visible.
    case clear
    /// The desktop, darkened.
    case dim
    /// The desktop, blurred like frosted glass.
    case frosted

    public var id: String { rawValue }
    public var titleKey: String { "saver.backdrop.\(rawValue)" }
}

/// Whether a design draws its own background (false over a see-through backdrop).
struct SaverDrawsBackgroundKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var saverDrawsBackground: Bool {
        get { self[SaverDrawsBackgroundKey.self] }
        set { self[SaverDrawsBackgroundKey.self] = newValue }
    }
}

/// Time helpers shared by the designs.
enum SaverClock {
    /// Whether the user's locale shows a 12-hour clock.
    static var uses12Hour: Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    static func hourMinute(_ date: Date) -> (hour: String, minute: String, period: String?) {
        let calendar = Calendar.current
        var hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        var period: String?
        if uses12Hour {
            let formatter = DateFormatter()
            formatter.locale = .current
            period = hour < 12 ? formatter.amSymbol : formatter.pmSymbol
            hour = hour % 12 == 0 ? 12 : hour % 12
        }
        return (uses12Hour ? "\(hour)" : String(format: "%02d", hour), String(format: "%02d", minute), period)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Seconds since midnight, with fractions (smooth hands and orbits).
    static func secondsOfDay(_ date: Date) -> Double {
        date.timeIntervalSince(Calendar.current.startOfDay(for: date))
    }

    /// Slow circular drift so nothing stays on the same pixels (burn-in protection).
    static func drift(_ date: Date, amplitude: CGFloat) -> CGSize {
        let phase = date.timeIntervalSinceReferenceDate / 300 * 2 * .pi
        return CGSize(width: cos(phase) * amplitude, height: sin(phase * 0.7) * amplitude * 0.6)
    }
}

/// Deterministic pseudo-random numbers (stars, rain columns) so frames and
/// thumbnails are stable.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
