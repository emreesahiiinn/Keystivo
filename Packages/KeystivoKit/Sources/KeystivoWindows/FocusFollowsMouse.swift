import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

/// Pure mapping from the pointer position to the window that should take focus.
nonisolated public enum PointerWindowResolver {
    /// One on-screen window, in window server (front to back) order.
    public struct Entry: Sendable, Hashable {
        public var id: CGWindowID
        public var pid: pid_t
        public var layer: Int
        /// Global coordinates, top-left origin (same space as `CGEvent.location`).
        public var bounds: CGRect
        public var alpha: Double

        public init(id: CGWindowID, pid: pid_t, layer: Int, bounds: CGRect, alpha: Double = 1) {
            self.id = id
            self.pid = pid
            self.layer = layer
            self.bounds = bounds
            self.alpha = alpha
        }
    }

    public static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))

    /// The normal window under `point`, or nil when the pointer is over the
    /// desktop, the Dock, the menu bar or any floating window, or while a menu
    /// is open. `passThrough` lists click-through windows to look beneath.
    public static func window(at point: CGPoint, in entries: [Entry], passThrough: Set<CGWindowID> = []) -> Entry? {
        // An open menu means the user is choosing something: never switch under it.
        if entries.contains(where: { $0.layer == popUpMenuLayer }) { return nil }
        for entry in entries where entry.bounds.contains(point) {
            if entry.alpha < 0.01 || passThrough.contains(entry.id) { continue }
            return entry.layer == 0 ? entry : nil
        }
        return nil
    }

    /// The front-most normal (layer 0) window under `point`, looking through
    /// anything above the normal layer: click-through overlays (ours or other
    /// apps') must not hide it. Callers that act on a click confirm the target
    /// with an Accessibility hit-test. Nil while a menu is open.
    public static func normalWindow(at point: CGPoint, in entries: [Entry]) -> Entry? {
        if entries.contains(where: { $0.layer == popUpMenuLayer }) { return nil }
        return entries.first { $0.layer == 0 && $0.alpha >= 0.01 && $0.bounds.contains(point) }
    }

    /// On-screen windows of the current Space, front to back.
    public static func onScreenWindows() -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            return Entry(id: id, pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                         bounds: bounds, alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// Whether `target` is already the active window: it belongs to the
    /// frontmost app and is that app's front-most normal window.
    public static func isActive(_ target: Entry, in entries: [Entry], frontmostPID: pid_t?) -> Bool {
        guard target.pid == frontmostPID else { return false }
        return entries.first { $0.pid == target.pid && $0.layer == 0 && $0.alpha >= 0.01 }?.id == target.id
    }
}

/// "Odak fareyi takip eder": when the pointer comes to rest on another window,
/// that window is raised and becomes active (AutoRaise / X11 style).
///
/// Only mouse-moved events are observed, and only while enabled. Nothing is
/// queried while the pointer moves: one window-server lookup runs when it has
/// rested for `delay`. Focus changes only when the pointer has entered a
/// different window, so nudging the mouse after ⌘Tab never undoes the switch.
@Observable
public final class FocusFollowsMouse: EventTapHandler {
    public static let shared = FocusFollowsMouse()

    public var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            reset()
            EventTapManager.shared.refresh()
        }
    }
    /// Seconds the pointer must rest on a window before it becomes active.
    public var delay: TimeInterval = 0.2
    public var excludedBundleIDs: Set<String> = []
    /// Keystivo's own modal UI (launcher, switcher, hints) pauses focusing.
    @ObservationIgnored public var isSuspended: () -> Bool = { false }

    /// Movement smaller than this (points) still counts as resting.
    private static let jitter: CGFloat = 4

    @ObservationIgnored private var restAnchor: CGPoint?
    /// Modifiers held during the last movement (moving with ⌘/⌥/⌃/⇧ keeps the current window).
    @ObservationIgnored private var movementModifiers: KeyModifiers = []
    @ObservationIgnored private var restTimer: Timer?
    /// Window the pointer last rested on.
    @ObservationIgnored private var lastRestWindow: CGWindowID?

    public init() {}

    public var eventTapPriority: Int { 1 }

    public var eventTapTypes: Set<CGEventType> {
        isEnabled ? [.mouseMoved] : []
    }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        let location = event.location
        movementModifiers = KeyModifiers(event.flags)
        if let restAnchor, hypot(location.x - restAnchor.x, location.y - restAnchor.y) < Self.jitter { return .pass }
        restAnchor = location
        if let restTimer, restTimer.isValid {
            restTimer.fireDate = Date(timeIntervalSinceNow: delay)
        } else {
            restTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerRested() }
            }
        }
        return .pass
    }

    private func pointerRested() {
        restAnchor = nil
        let modifiers = movementModifiers.union(KeyModifiers(NSEvent.modifierFlags))
        guard isEnabled, NSEvent.pressedMouseButtons == 0,
              modifiers.intersection([.command, .option, .control, .shift]).isEmpty,
              !isSuspended(), let point = CGEvent(source: nil)?.location else { return }
        let entries = PointerWindowResolver.onScreenWindows()
        let target = PointerWindowResolver.window(at: point, in: entries, passThrough: Self.ownPassThroughWindows())
        let previous = lastRestWindow
        lastRestWindow = target?.id
        guard let target, target.id != previous,
              !PointerWindowResolver.isActive(target, in: entries, frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        else { return }
        if target.pid == getpid() {
            guard let window = NSApp.window(withWindowNumber: Int(target.id)), window.canBecomeKey else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier, excludedBundleIDs.contains(bundleID) { return }
        let app = AXElement.application(pid: target.pid)
        app.setMessagingTimeout(0.25)
        let window = app.windows.first { $0.windowID == target.id }
        WindowFocus.focus(window: window ?? app, windowID: target.id, pid: target.pid)
    }

    private func reset() {
        restTimer?.invalidate()
        restTimer = nil
        restAnchor = nil
        lastRestWindow = nil
    }

    /// Our own click-through overlays (HUDs, highlights) must not hide what is beneath.
    public static func ownPassThroughWindows() -> Set<CGWindowID> {
        Set(NSApp.windows.filter { $0.isVisible && ($0.ignoresMouseEvents || $0.alphaValue < 0.01) }.map { CGWindowID($0.windowNumber) })
    }
}
