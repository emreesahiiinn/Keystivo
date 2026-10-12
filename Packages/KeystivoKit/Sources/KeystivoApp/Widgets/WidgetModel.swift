import Foundation

/// Keystivo widgets: small live panels on the desktop or in the menu bar panel.
nonisolated struct WidgetSettings: Codable, Hashable, Sendable {
    var instances: [WidgetInstance] = []
    var showsDesktopWidgets = true
    /// Desktop widgets float above windows instead of sitting on the desktop.
    var alwaysOnTop = false
    var background: PanelBackground = .glass

    var desktop: [WidgetInstance] { instances.filter { $0.placement == .desktop } }
    var panel: [WidgetInstance] { instances.filter { $0.placement == .panel } }
}

nonisolated enum WidgetKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case clock, worldClock, calendar, timer, system, battery, weather, notes, shortcuts, clipboard, countdown

    var id: String { rawValue }
    var titleKey: String { "widget.kind.\(rawValue)" }
    var helpKey: String { "widget.kind.\(rawValue).help" }

    var symbol: String {
        switch self {
        case .clock: "clock.fill"
        case .worldClock: "globe"
        case .calendar: "calendar"
        case .timer: "timer"
        case .system: "gauge.with.dots.needle.50percent"
        case .battery: "battery.75percent"
        case .weather: "cloud.sun.fill"
        case .notes: "note.text"
        case .shortcuts: "square.grid.2x2.fill"
        case .clipboard: "list.clipboard.fill"
        case .countdown: "hourglass"
        }
    }

    var sizes: [WidgetSize] {
        switch self {
        case .countdown, .battery: [.small, .medium]
        case .timer: [.small, .medium]
        case .clipboard: [.medium, .large]
        default: WidgetSize.allCases
        }
    }

    var defaultSize: WidgetSize {
        switch self {
        case .clock, .timer, .battery, .countdown: .small
        default: .medium
        }
    }
}

nonisolated enum WidgetSize: String, Codable, Hashable, Sendable, CaseIterable {
    case small, medium, large

    var titleKey: String { "widget.size.\(rawValue)" }

    /// Points on the desktop (macOS widget proportions).
    var points: CGSize {
        switch self {
        case .small: CGSize(width: 164, height: 164)
        case .medium: CGSize(width: 344, height: 164)
        case .large: CGSize(width: 344, height: 344)
        }
    }
}

nonisolated enum WidgetPlacement: String, Codable, Hashable, Sendable {
    case desktop, panel
}

/// One widget and its options (only those of its kind are used).
nonisolated struct WidgetInstance: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var kind: WidgetKind
    var size: WidgetSize
    var placement: WidgetPlacement = .desktop
    /// Window origin on screen (AppKit coordinates); nil = placed automatically.
    var origin: CGPoint?

    // Clock
    var showsSeconds = false
    // World clocks
    var timeZones: [String] = ["America/New_York", "Europe/London", "Asia/Tokyo"]
    // Weather
    var city = ""
    var latitude: Double?
    var longitude: Double?
    // Shortcuts
    var actions: [String] = ["launcher.show", "clipboard.history", "tools.captureText", "system.lockScreen"]
    // Countdown
    var title = ""
    var targetDate: Date?
    // Timer
    var timerMinutes = 25

    init(kind: WidgetKind, size: WidgetSize? = nil, placement: WidgetPlacement = .desktop) {
        self.kind = kind
        self.size = size ?? kind.defaultSize
        self.placement = placement
        if kind == .countdown {
            targetDate = Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: .now) + 1, month: 1, day: 1))
        }
    }
}
