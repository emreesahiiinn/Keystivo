import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

/// The three title bar buttons.
nonisolated public enum WindowButton: String, Codable, Hashable, Sendable, CaseIterable {
    case close, minimize, zoom

    /// Recognizes a button from its Accessibility subrole.
    public init?(subrole: String?) {
        switch subrole {
        case kAXCloseButtonSubrole: self = .close
        case kAXMinimizeButtonSubrole: self = .minimize
        case kAXZoomButtonSubrole, "AXFullScreenButton": self = .zoom
        default: return nil
        }
    }
}

/// What clicking a title bar button does instead of the usual.
nonisolated public enum WindowButtonAction: String, Codable, Hashable, Sendable, CaseIterable {
    /// macOS's own behavior.
    case standard
    case closeWindow
    /// Closes the window, and quits the app when it was its last window (Swift Quit-style).
    case closeAndQuitIfLast
    case quitApp
    case minimize
    case hideApp
    /// Fills the screen without entering full screen.
    case maximize
    case almostMaximize
    case toggleFullScreen
    case center
    case leftHalf
    case rightHalf

    public var titleKey: String { "windowButtons.action.\(rawValue)" }
}

/// The decision part of the engine; pure and unit-tested.
nonisolated public enum WindowButtonGeometry {
    /// Where traffic lights can be: the top-left corner of a window (taller for unified toolbars).
    public static func isInButtonArea(_ point: CGPoint, window: CGRect) -> Bool {
        let x = point.x - window.minX, y = point.y - window.minY
        return x >= 0 && x <= 96 && y >= 0 && y <= 60
    }
}

/// Customizes the red, yellow and green window buttons: e.g. red quits the app,
/// yellow fills the screen, green minimizes (BetterTouchTool-style).
///
/// Only clicks in a window's top-left corner are examined, and only those that
/// land on a title bar button with a custom action are taken over.
@Observable
public final class WindowButtonEngine: EventTapHandler {
    public static let shared = WindowButtonEngine()

    public var isEnabled = false {
        didSet { if isEnabled != oldValue { EventTapManager.shared.refresh() } }
    }
    /// "close.click", "zoom.rightClick"… → action (missing = standard).
    public var actions: [String: WindowButtonAction] = [:] {
        didSet { EventTapManager.shared.refresh() }
    }
    public var excludedBundleIDs: Set<String> = []

    public static func key(_ button: WindowButton, rightClick: Bool) -> String {
        "\(button.rawValue).\(rightClick ? "rightClick" : "click")"
    }

    public func action(for button: WindowButton, rightClick: Bool) -> WindowButtonAction {
        actions[Self.key(button, rightClick: rightClick)] ?? .standard
    }

    /// The mouse-up of a click we took over must not reach the app either.
    @ObservationIgnored private var swallowUp: CGEventType?

    public init() {}

    public var eventTapPriority: Int { 60 }

    public var eventTapTypes: Set<CGEventType> {
        guard isEnabled, actions.values.contains(where: { $0 != .standard }) else { return [] }
        var types: Set<CGEventType> = []
        if actions.contains(where: { $0.key.hasSuffix(".click") && $0.value != .standard }) { types.formUnion([.leftMouseDown, .leftMouseUp]) }
        if actions.contains(where: { $0.key.hasSuffix(".rightClick") && $0.value != .standard }) { types.formUnion([.rightMouseDown, .rightMouseUp]) }
        return types
    }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        switch type {
        case .leftMouseUp, .rightMouseUp:
            if swallowUp == type {
                swallowUp = nil
                return .consume
            }
            return .pass
        case .leftMouseDown, .rightMouseDown:
            // Modified clicks keep their system meaning (e.g. ⌥-click on green).
            guard KeyModifiers(event.flags).intersection([.command, .option, .control, .shift]).isEmpty else { return .pass }
            let rightClick = type == .rightMouseDown
            guard let hit = target(at: event.location) else { return .pass }
            let action = action(for: hit.button, rightClick: rightClick)
            guard action != .standard else { return .pass }
            swallowUp = rightClick ? .rightMouseUp : .leftMouseUp
            DispatchQueue.main.async { [weak self] in
                self?.perform(action, button: hit.element, window: hit.window, pid: hit.pid)
            }
            return .consume
        default:
            return .pass
        }
    }

    /// The title bar button of another app's window that a click at `location` would hit.
    public func target(at location: CGPoint) -> (button: WindowButton, element: AXElement, window: AXElement?, pid: pid_t)? {
        // Cheap window-server check first: most clicks are nowhere near a title bar button.
        // Overlays above the normal layer (e.g. the click-through presentation overlay)
        // are looked through; the Accessibility hit-test below confirms the button
        // really is what receives the click.
        guard let window = PointerWindowResolver.normalWindow(at: location, in: PointerWindowResolver.onScreenWindows()),
              window.pid != getpid(),
              WindowButtonGeometry.isInButtonArea(location, window: window.bounds) else { return nil }
        if let bundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier, excludedBundleIDs.contains(bundleID) { return nil }
        guard let hit = Self.button(at: location, pid: window.pid) else { return nil }
        return (hit.button, hit.element, hit.window, window.pid)
    }

    /// The title bar button under `point`, if any: by the hit element's subrole, or
    /// (when the hit lands on something inside the button) by the window's button frames.
    public static func button(at point: CGPoint, pid: pid_t) -> (button: WindowButton, element: AXElement, window: AXElement?)? {
        guard let element = AXElement.element(at: point), element.pid == pid else { return nil }
        // Custom title bars (Catalyst, Electron) may hit an element without a window link.
        let window = element.role == kAXWindowRole ? element
            : element.element(kAXWindowAttribute)
            ?? AXElement.application(pid: pid).windows.first { $0.frame?.contains(point) == true }
        if element.role == kAXButtonRole, let button = WindowButton(subrole: element.subrole) {
            return (button, element, window)
        }
        guard let window else { return nil }
        let candidates: [(String, WindowButton)] = [(kAXCloseButtonAttribute, .close), (kAXMinimizeButtonAttribute, .minimize), (kAXZoomButtonAttribute, .zoom)]
        for (attribute, kind) in candidates {
            if let button = window.element(attribute), let frame = button.frame, frame.insetBy(dx: -2, dy: -2).contains(point) {
                return (kind, button, window)
            }
        }
        return nil
    }

    private func perform(_ action: WindowButtonAction, button: AXElement, window: AXElement?, pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        let manager = WindowManager.shared
        switch action {
        case .standard:
            break
        case .closeWindow:
            closeWindow(button: button, window: window)
        case .closeAndQuitIfLast:
            closeWindow(button: button, window: window)
            // Give the app a moment to close it (or to ask about unsaved changes).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let remaining = AXElement.application(pid: pid).windows.filter { $0.isStandardWindow && !$0.isMinimized }
                if remaining.isEmpty { app?.terminate() }
            }
        case .quitApp:
            app?.terminate()
        case .minimize:
            window?.setMinimized(true)
        case .hideApp:
            app?.hide()
        case .maximize, .almostMaximize, .center, .leftHalf, .rightHalf:
            guard let window else { return }
            let position: SnapPosition = switch action {
            case .almostMaximize: .almostMaximize
            case .center: .center
            case .leftHalf: .leftHalf
            case .rightHalf: .rightHalf
            default: .maximize
            }
            if window.isFullScreen { window.setFullScreen(false) }
            manager.snap(window, to: position)
        case .toggleFullScreen:
            guard let window else { return }
            window.setFullScreen(!window.isFullScreen)
        }
    }

    private func closeWindow(button: AXElement, window: AXElement?) {
        if !button.press() { window?.close() }
    }
}
