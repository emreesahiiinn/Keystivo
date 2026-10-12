import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

/// Pure geometry for modifier-drag resizing.
nonisolated public enum ModifierDragGeometry {
    public static let minimumSize = CGSize(width: 160, height: 100)

    /// Which corner follows the pointer: the one nearest to where the drag began.
    public static func corner(for point: CGPoint, in frame: CGRect) -> (left: Bool, top: Bool) {
        (point.x < frame.midX, point.y < frame.midY)
    }

    /// `frame` resized by `delta` (AX coordinates, top-left origin) from `corner`.
    public static func resized(_ frame: CGRect, by delta: CGSize, corner: (left: Bool, top: Bool)) -> CGRect {
        var result = frame
        if corner.left {
            let width = max(minimumSize.width, frame.width - delta.width)
            result.origin.x = frame.maxX - width
            result.size.width = width
        } else {
            result.size.width = max(minimumSize.width, frame.width + delta.width)
        }
        if corner.top {
            let height = max(minimumSize.height, frame.height - delta.height)
            result.origin.y = frame.maxY - height
            result.size.height = height
        } else {
            result.size.height = max(minimumSize.height, frame.height + delta.height)
        }
        return result
    }
}

/// Move a window by dragging anywhere in it, or resize it by right-dragging,
/// while holding modifier keys (Easy Move+Resize / BetterTouchTool style).
///
/// Mouse events are observed only while enabled, and only drags that start
/// with the modifiers held are taken over; every other click passes through.
@Observable
public final class ModifierDragEngine: EventTapHandler {
    public static let shared = ModifierDragEngine()

    public var isEnabled = false {
        didSet { if isEnabled != oldValue { EventTapManager.shared.refresh() } }
    }
    /// Keys to hold (default ⌃⌥).
    public var modifiers: KeyModifiers = [.control, .option]
    /// Bring the window to the front when a drag starts.
    public var raisesWindow = true
    public var excludedBundleIDs: Set<String> = []

    private enum Mode { case move, resize }

    private struct Session {
        let mode: Mode
        let startPointer: CGPoint
        var window: AXElement?
        var startFrame: CGRect?
        var corner: (left: Bool, top: Bool) = (false, false)
    }

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var pendingFrame: CGRect?
    @ObservationIgnored private var applyScheduled = false

    public init() {}

    // Above drag-to-snap, so its preview doesn't fight the move.
    public var eventTapPriority: Int { 45 }

    public var eventTapTypes: Set<CGEventType> {
        isEnabled ? [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp] : []
    }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            let held = KeyModifiers(event.flags).intersection([.command, .option, .control, .shift])
            guard !modifiers.isEmpty, held == modifiers else { return .pass }
            let location = event.location
            session = Session(mode: type == .leftMouseDown ? .move : .resize, startPointer: location)
            // Hit-test outside the tap callback; drags arriving meanwhile are swallowed.
            DispatchQueue.main.async { [weak self] in self?.identifyWindow(at: location) }
            return .consume
        case .leftMouseDragged, .rightMouseDragged:
            guard let session else { return .pass }
            if let frame = frame(for: event.location, session: session) { schedule(frame, for: session) }
            return .consume
        case .leftMouseUp, .rightMouseUp:
            guard session != nil else { return .pass }
            session = nil
            return .consume
        default:
            return .pass
        }
    }

    private func identifyWindow(at location: CGPoint) {
        guard var current = session, current.window == nil,
              let element = AXElement.element(at: location),
              let window = element.role == kAXWindowRole ? element : element.element(kAXWindowAttribute),
              let pid = window.pid, pid != getpid(), !window.isFullScreen,
              let frame = window.frame else {
            return
        }
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, excludedBundleIDs.contains(bundleID) {
            session = nil
            return
        }
        current.window = window
        current.startFrame = frame
        current.corner = ModifierDragGeometry.corner(for: location, in: frame)
        session = current
        if raisesWindow { WindowFocus.focus(window: window, pid: pid) }
    }

    private func frame(for pointer: CGPoint, session: Session) -> CGRect? {
        guard let start = session.startFrame else { return nil }
        let delta = CGSize(width: pointer.x - session.startPointer.x, height: pointer.y - session.startPointer.y)
        switch session.mode {
        case .move: return start.offsetBy(dx: delta.width, dy: delta.height)
        case .resize: return ModifierDragGeometry.resized(start, by: delta, corner: session.corner)
        }
    }

    /// Only the latest frame is applied; Accessibility calls never queue up behind the pointer.
    private func schedule(_ frame: CGRect, for session: Session) {
        pendingFrame = frame
        guard !applyScheduled, let window = session.window else { return }
        applyScheduled = true
        let mode = session.mode
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            applyScheduled = false
            guard let frame = pendingFrame else { return }
            pendingFrame = nil
            switch mode {
            case .move: _ = window.setPosition(frame.integral.origin)
            case .resize: window.setFrame(frame.integral)
            }
        }
    }
}
