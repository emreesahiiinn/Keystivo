import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

nonisolated public enum DisplayTarget: String, Codable, Sendable, CaseIterable {
    case next, previous, left, right, up, down

    public var titleKey: String { "display.\(rawValue)" }
}

/// A recorded frame change, for undo and the window history list.
nonisolated public struct WindowMove: Identifiable, Sendable {
    public let id = UUID()
    public let windowID: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let title: String
    public let from: CGRect
    public let to: CGRect
    public let date: Date
}

public enum WindowManagerError: LocalizedError {
    case noFocusedWindow
    case notResizable

    public var errorDescription: String? {
        switch self {
        case .noFocusedWindow: L("windows.error.noFocusedWindow")
        case .notResizable: L("windows.error.notResizable")
        }
    }
}

/// Moves and resizes windows through the Accessibility API.
@Observable
public final class WindowManager {
    public static let shared = WindowManager()

    /// Spacing between snapped windows and screen edges.
    public var gap: CGFloat = 0
    /// Pressing the same half shortcut repeatedly cycles ½ → ⅔ → ⅓.
    public var cyclesOnRepeat = true
    /// Moving to another display keeps the snapped position instead of scaling.
    public var preserveSnapAcrossDisplays = true
    /// Repeating ← / → half at the screen edge continues onto the neighboring display.
    public var repeatMovesAcrossDisplays = false
    /// A snapped window gets its earlier size back when it's dragged away.
    public var restoresSizeOnDrag = true

    public private(set) var moves: [WindowMove] = []

    @ObservationIgnored private var originalFrames: [CGWindowID: CGRect] = [:]
    @ObservationIgnored private var lastSnap: (windowID: CGWindowID, position: SnapPosition, date: Date)?
    @ObservationIgnored private var snapped: [CGWindowID: SnapPosition] = [:]

    public init() {}

    // MARK: Focused window helpers

    public func focusedWindow() throws(WindowManagerError) -> AXElement {
        guard let window = WindowCatalog.shared.focusedWindow() else { throw .noFocusedWindow }
        return window
    }

    // MARK: Snapping

    public func snapFocused(_ position: SnapPosition) throws(WindowManagerError) {
        let window = try focusedWindow()
        // Already in this half: continue onto the display on that side (Rectangle-style).
        if repeatMovesAcrossDisplays, let id = window.windowID, snapped[id] == position,
           position == .leftHalf || position == .rightHalf,
           let current = window.frame, let source = ScreenGeometry.screen(forAXRect: current),
           let neighbor = screen(from: source, target: position == .leftHalf ? .left : .right), neighbor != source {
            snap(window, to: position == .leftHalf ? .rightHalf : .leftHalf, on: neighbor)
            return
        }
        var target = position
        if cyclesOnRepeat, let last = lastSnap, let id = window.windowID, last.windowID == id,
           Date.now.timeIntervalSince(last.date) < 1.5, let next = SnapGeometry.cycle(after: last.position),
           sameFamily(position, last.position) {
            target = next
        }
        snap(window, to: target)
    }

    private func sameFamily(_ requested: SnapPosition, _ last: SnapPosition) -> Bool {
        let left: Set<SnapPosition> = [.leftHalf, .firstTwoThirds, .firstThird]
        let right: Set<SnapPosition> = [.rightHalf, .lastTwoThirds, .lastThird]
        return (left.contains(requested) && left.contains(last)) || (right.contains(requested) && right.contains(last))
    }

    public func snap(_ window: AXElement, to position: SnapPosition, on screen: NSScreen? = nil) {
        guard let current = window.frame else { return }
        let screen = screen ?? ScreenGeometry.screen(forAXRect: current) ?? NSScreen.main
        guard let screen else { return }
        let area = ScreenGeometry.visibleFrameAX(of: screen)
        let target = SnapGeometry.frame(for: position, in: area, gap: gap, current: current).integral
        if let id = window.windowID {
            if originalFrames[id] == nil || snapped[id] == nil { originalFrames[id] = current }
            snapped[id] = position
            lastSnap = (id, position, .now)
        }
        apply(target, to: window, from: current)
    }

    /// Restores the frame the window had before its first snap.
    public func restoreFocused() throws(WindowManagerError) {
        let window = try focusedWindow()
        guard let id = window.windowID, let original = originalFrames[id], let current = window.frame else { return }
        snapped[id] = nil
        originalFrames[id] = nil
        apply(original, to: window, from: current)
    }

    /// The size a window had before Keystivo snapped it, if it's still snapped.
    public func presnapFrame(of windowID: CGWindowID) -> CGRect? {
        snapped[windowID] == nil ? nil : originalFrames[windowID]
    }

    /// Forgets snap state (e.g. the user moved the window away by hand).
    public func forgetSnap(of windowID: CGWindowID) {
        snapped[windowID] = nil
        originalFrames[windowID] = nil
    }

    // MARK: Edges

    public enum Edge: String, CaseIterable, Sendable { case left, right, top, bottom }

    /// Moves the window flush against an edge of its screen without resizing it.
    public func moveFocused(toEdge edge: Edge) throws(WindowManagerError) {
        let window = try focusedWindow()
        guard let current = window.frame, let screen = ScreenGeometry.screen(forAXRect: current) ?? NSScreen.main else { return }
        let area = ScreenGeometry.visibleFrameAX(of: screen).insetBy(dx: gap, dy: gap)
        var frame = current
        switch edge {
        case .left: frame.origin.x = area.minX
        case .right: frame.origin.x = area.maxX - frame.width
        case .top: frame.origin.y = area.minY
        case .bottom: frame.origin.y = area.maxY - frame.height
        }
        apply(frame.integral, to: window, from: current)
    }

    /// Grows or shrinks only the width or only the height, around the center.
    public func resizeFocused(axis: Axis, larger: Bool, step: CGFloat = 60) throws(WindowManagerError) {
        let window = try focusedWindow()
        guard let current = window.frame, let screen = ScreenGeometry.screen(forAXRect: current) ?? NSScreen.main else { return }
        let area = ScreenGeometry.visibleFrameAX(of: screen)
        let delta = larger ? step : -step
        var frame = current
        switch axis {
        case .horizontal:
            frame.size.width = min(max(current.width + delta, 200), area.width)
            frame.origin.x = min(max(current.midX - frame.width / 2, area.minX), area.maxX - frame.width)
        case .vertical:
            frame.size.height = min(max(current.height + delta, 150), area.height)
            frame.origin.y = min(max(current.midY - frame.height / 2, area.minY), area.maxY - frame.height)
        }
        apply(frame.integral, to: window, from: current)
    }

    public enum Axis: Sendable { case horizontal, vertical }

    // MARK: Displays

    public func moveFocused(to target: DisplayTarget) throws(WindowManagerError) {
        let window = try focusedWindow()
        move(window, to: target)
    }

    public func move(_ window: AXElement, to target: DisplayTarget) {
        guard let current = window.frame, let source = ScreenGeometry.screen(forAXRect: current),
              let destination = screen(from: source, target: target), destination != source else { return }
        if preserveSnapAcrossDisplays, let id = window.windowID, let position = snapped[id] {
            snap(window, to: position, on: destination)
            return
        }
        let frame = SnapGeometry.translate(
            current,
            from: ScreenGeometry.visibleFrameAX(of: source),
            to: ScreenGeometry.visibleFrameAX(of: destination)
        )
        apply(frame, to: window, from: current)
    }

    /// Moves the window to a specific display (index in left-to-right order).
    public func move(_ window: AXElement, toDisplayIndex index: Int) {
        let screens = ScreenGeometry.orderedScreens
        guard screens.indices.contains(index), let current = window.frame,
              let source = ScreenGeometry.screen(forAXRect: current) else { return }
        let frame = SnapGeometry.translate(
            current,
            from: ScreenGeometry.visibleFrameAX(of: source),
            to: ScreenGeometry.visibleFrameAX(of: screens[index])
        )
        apply(frame, to: window, from: current)
    }

    private func screen(from source: NSScreen, target: DisplayTarget) -> NSScreen? {
        let screens = ScreenGeometry.orderedScreens
        guard screens.count > 1, let index = screens.firstIndex(of: source) else { return nil }
        switch target {
        case .next: return screens[(index + 1) % screens.count]
        case .previous: return screens[(index - 1 + screens.count) % screens.count]
        case .left, .right, .up, .down:
            let origin = CGPoint(x: source.frame.midX, y: source.frame.midY)
            let candidates = screens.filter { $0 != source }.filter { screen in
                switch target {
                case .left: screen.frame.midX < origin.x
                case .right: screen.frame.midX > origin.x
                case .up: screen.frame.midY > origin.y
                case .down: screen.frame.midY < origin.y
                default: false
                }
            }
            return candidates.min { hypot($0.frame.midX - origin.x, $0.frame.midY - origin.y) < hypot($1.frame.midX - origin.x, $1.frame.midY - origin.y) }
        }
    }

    // MARK: Resize & nudge

    public func resizeFocused(larger: Bool, step: CGFloat = 40) throws(WindowManagerError) {
        let window = try focusedWindow()
        guard let current = window.frame, let screen = ScreenGeometry.screen(forAXRect: current) else { return }
        let area = ScreenGeometry.visibleFrameAX(of: screen)
        let frame = SnapGeometry.resize(current, by: larger ? step : -step, within: area)
        apply(frame, to: window, from: current)
    }

    public func nudgeFocused(dx: CGFloat, dy: CGFloat) throws(WindowManagerError) {
        let window = try focusedWindow()
        guard let current = window.frame, let screen = ScreenGeometry.screen(forAXRect: current) else { return }
        let frame = SnapGeometry.nudge(current, dx: dx, dy: dy, within: ScreenGeometry.visibleFrameAX(of: screen))
        apply(frame, to: window, from: current)
    }

    public func setFrame(_ frame: CGRect, for window: AXElement) {
        guard let current = window.frame else { return }
        apply(frame, to: window, from: current)
    }

    // MARK: Misc window commands

    public func minimizeFocused() throws(WindowManagerError) { try focusedWindow().setMinimized(true) }
    public func closeFocused() throws(WindowManagerError) { try focusedWindow().close() }

    public func toggleFullScreenFocused() throws(WindowManagerError) {
        let window = try focusedWindow()
        window.setFullScreen(!window.isFullScreen)
    }

    /// Reverts the most recent move performed by Keystivo.
    public func undoLastMove() {
        guard let move = moves.first else { return }
        moves.removeFirst()
        let app = AXElement.application(pid: move.pid)
        guard let window = app.windows.first(where: { $0.windowID == move.windowID }) else { return }
        perform(move.from, on: window)
    }

    // MARK: Applying frames

    private func apply(_ frame: CGRect, to window: AXElement, from current: CGRect) {
        guard frame != current else { return }
        perform(frame, on: window)
        if let id = window.windowID, let pid = window.pid {
            let move = WindowMove(
                windowID: id, pid: pid,
                appName: NSRunningApplication(processIdentifier: pid)?.localizedName ?? "",
                title: window.title ?? "", from: current, to: frame, date: .now
            )
            moves.insert(move, at: 0)
            if moves.count > 100 { moves.removeLast() }
        }
    }

    /// Applies a frame, temporarily disabling "enhanced user interface" which
    /// makes some apps (e.g. those observed by assistive tools) animate slowly.
    private func perform(_ frame: CGRect, on window: AXElement) {
        var appElement: AXElement?
        var restoreEnhanced = false
        if let pid = window.pid {
            let app = AXElement.application(pid: pid)
            if (app.attribute("AXEnhancedUserInterface") as Bool?) == true {
                app.set("AXEnhancedUserInterface", kCFBooleanFalse)
                appElement = app
                restoreEnhanced = true
            }
        }
        window.setFrame(frame)
        if restoreEnhanced { appElement?.set("AXEnhancedUserInterface", kCFBooleanTrue) }
    }
}
