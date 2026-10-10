import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

nonisolated public enum ArrangementStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case grid, cascade, masterStack, columns, rows
    public var id: String { rawValue }
    public var titleKey: String { "arrange.\(rawValue)" }
}

nonisolated public enum ArrangementScope: String, Codable, Sendable, CaseIterable {
    /// Visible windows on the screen of the focused window.
    case currentScreen
    /// Windows of the frontmost application only.
    case frontmostApp
    public var titleKey: String { "arrange.scope.\(rawValue)" }
}

/// Window stacking/tiling (feature: "pencere istifleme").
public enum WindowArranger {
    public static func arrange(_ style: ArrangementStyle, scope: ArrangementScope, gap: CGFloat) async {
        guard let focused = WindowCatalog.shared.focusedWindow(), let focusedFrame = focused.frame,
              let screen = ScreenGeometry.screen(forAXRect: focusedFrame) else { return }
        var options = WindowCatalog.Options()
        options.includeMinimized = false
        options.includeHiddenApps = false
        options.includeOtherSpaces = false
        var windows = await WindowCatalog.shared.windows(options: options)
        switch scope {
        case .currentScreen:
            windows = windows.filter { ScreenGeometry.screen(forAXRect: $0.frame) == screen }
        case .frontmostApp:
            let pid = focused.pid
            windows = windows.filter { $0.pid == pid }
        }
        let elements = windows.compactMap(\.element)
        guard !elements.isEmpty else { return }
        let area = ScreenGeometry.visibleFrameAX(of: screen)
        let frames: [CGRect] = switch style {
        case .grid: SnapGeometry.gridFrames(count: elements.count, in: area, gap: gap)
        case .cascade: SnapGeometry.cascadeFrames(count: elements.count, in: area.insetBy(dx: gap, dy: gap))
        case .masterStack: SnapGeometry.stackFrames(count: elements.count, in: area, gap: gap)
        case .columns: columns(count: elements.count, in: area, gap: gap)
        case .rows: rows(count: elements.count, in: area, gap: gap)
        }
        // Cascade back-to-front so the frontmost window stays on top.
        let pairs = style == .cascade ? Array(zip(elements.reversed(), frames)) : Array(zip(elements, frames))
        for (window, frame) in pairs {
            WindowManager.shared.setFrame(frame, for: window)
            if style == .cascade { window.raise() }
        }
        focused.raise()
    }

    /// Brings every window of every app onto the focused window's screen.
    public static func gatherToCurrentScreen() async {
        guard let focused = WindowCatalog.shared.focusedWindow(), let frame = focused.frame,
              let target = ScreenGeometry.screen(forAXRect: frame) else { return }
        var options = WindowCatalog.Options()
        options.includeOtherSpaces = false
        options.includeMinimized = false
        for window in await WindowCatalog.shared.windows(options: options) {
            guard let element = window.element, let source = ScreenGeometry.screen(forAXRect: window.frame), source != target else { continue }
            let moved = SnapGeometry.translate(window.frame, from: ScreenGeometry.visibleFrameAX(of: source), to: ScreenGeometry.visibleFrameAX(of: target))
            WindowManager.shared.setFrame(moved, for: element)
        }
    }

    private static func columns(count: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        let inner = area.insetBy(dx: gap, dy: gap)
        let width = (inner.width - gap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { CGRect(x: inner.minX + CGFloat($0) * (width + gap), y: inner.minY, width: width, height: inner.height).integral }
    }

    private static func rows(count: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        let inner = area.insetBy(dx: gap, dy: gap)
        let height = (inner.height - gap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { CGRect(x: inner.minX, y: inner.minY + CGFloat($0) * (height + gap), width: inner.width, height: height).integral }
    }
}

// MARK: - Default window positions per app

nonisolated public enum WindowPlacement: Codable, Hashable, Sendable {
    case snap(SnapPosition)
    /// Relative frame (0…1) within the display's visible area.
    case relative(CGRect)
}

nonisolated public enum DisplayPreference: String, Codable, Hashable, Sendable, CaseIterable {
    case current, main, mouse
    public var titleKey: String { "displayPreference.\(rawValue)" }
}

/// "Uygulama başına varsayılan pencere konumu".
nonisolated public struct AppWindowRule: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var bundleID: String
    public var placement: WindowPlacement
    public var display: DisplayPreference = .current
    /// Apply to every new window, or only the first window after launch.
    public var everyNewWindow = false
    public var isEnabled = true

    public init(bundleID: String, placement: WindowPlacement) {
        self.bundleID = bundleID
        self.placement = placement
    }
}

/// Applies ``AppWindowRule``s as windows appear.
@Observable
public final class DefaultPositionService {
    public static let shared = DefaultPositionService()

    public var rules: [AppWindowRule] = []
    @ObservationIgnored private var subscription: UUID?
    @ObservationIgnored private var appliedFirstWindow: Set<pid_t> = []

    public init() {}

    public func start(hub: WindowEventHub = .shared) {
        guard subscription == nil else { return }
        subscription = hub.subscribe { [weak self] event in
            guard let self else { return }
            switch event {
            case .windowCreated(let pid, let window):
                self.handleNewWindow(pid: pid, window: window)
            case .appTerminated(let pid, _):
                self.appliedFirstWindow.remove(pid)
            default:
                break
            }
        }
    }

    private func handleNewWindow(pid: pid_t, window: AXElement) {
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let rule = rules.first(where: { $0.isEnabled && $0.bundleID == bundleID }) else { return }
        if !rule.everyNewWindow {
            guard !appliedFirstWindow.contains(pid) else { return }
            appliedFirstWindow.insert(pid)
        }
        // Apps often position their own windows right after creation; apply after that.
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            apply(rule, to: window)
        }
    }

    public func apply(_ rule: AppWindowRule, to window: AXElement) {
        guard window.isStandardWindow else { return }
        let screen: NSScreen? = switch rule.display {
        case .current: window.frame.flatMap(ScreenGeometry.screen(forAXRect:)) ?? NSScreen.main
        case .main: NSScreen.screens.first
        case .mouse: NSScreen.underMouse
        }
        guard let screen else { return }
        switch rule.placement {
        case .snap(let position):
            WindowManager.shared.snap(window, to: position, on: screen)
        case .relative(let rect):
            let area = ScreenGeometry.visibleFrameAX(of: screen)
            let frame = CGRect(x: area.minX + rect.minX * area.width, y: area.minY + rect.minY * area.height,
                               width: rect.width * area.width, height: rect.height * area.height).integral
            WindowManager.shared.setFrame(frame, for: window)
        }
    }

    /// Captures the focused window's current placement as a rule for its app.
    public func ruleFromFocusedWindow() -> AppWindowRule? {
        guard let window = WindowCatalog.shared.focusedWindow(), let frame = window.frame,
              let pid = window.pid, let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let screen = ScreenGeometry.screen(forAXRect: frame) else { return nil }
        let area = ScreenGeometry.visibleFrameAX(of: screen)
        let relative = CGRect(x: (frame.minX - area.minX) / area.width, y: (frame.minY - area.minY) / area.height,
                              width: frame.width / area.width, height: frame.height / area.height)
        return AppWindowRule(bundleID: bundleID, placement: .relative(relative))
    }
}
