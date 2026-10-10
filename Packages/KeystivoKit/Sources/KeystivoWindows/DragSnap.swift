import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

/// Pure mapping from pointer position to a snap target while dragging a window.
nonisolated public enum DragSnapZones {
    public struct Configuration: Sendable, Hashable {
        /// Distance from an edge (points) that activates a zone.
        public var edgeThreshold: CGFloat = 6
        /// Size of the corner hot areas along each edge.
        public var cornerSize: CGFloat = 140
        public var topEdgeMaximizes = true
        /// Dragging along the bottom edge snaps to thirds.
        public var bottomEdgeThirds = true
        public init() {}
    }

    /// `point` and `screen` are in Cocoa coordinates (bottom-left origin).
    public static func position(for point: CGPoint, in screen: CGRect, configuration: Configuration = Configuration()) -> SnapPosition? {
        let threshold = configuration.edgeThreshold
        let corner = configuration.cornerSize
        let atLeft = point.x <= screen.minX + threshold
        let atRight = point.x >= screen.maxX - threshold
        let atTop = point.y >= screen.maxY - threshold
        let atBottom = point.y <= screen.minY + threshold
        let nearTop = point.y >= screen.maxY - corner
        let nearBottom = point.y <= screen.minY + corner
        let nearLeft = point.x <= screen.minX + corner
        let nearRight = point.x >= screen.maxX - corner

        if atLeft {
            if nearTop { return .topLeftQuarter }
            if nearBottom { return .bottomLeftQuarter }
            return .leftHalf
        }
        if atRight {
            if nearTop { return .topRightQuarter }
            if nearBottom { return .bottomRightQuarter }
            return .rightHalf
        }
        if atTop {
            if nearLeft { return .topLeftQuarter }
            if nearRight { return .topRightQuarter }
            return configuration.topEdgeMaximizes ? .maximize : .topHalf
        }
        if atBottom {
            if nearLeft { return .bottomLeftQuarter }
            if nearRight { return .bottomRightQuarter }
            guard configuration.bottomEdgeThirds else { return .bottomHalf }
            let third = screen.width / 3
            switch point.x - screen.minX {
            case ..<third: return .firstThird
            case ..<(third * 2): return .centerThird
            default: return .lastThird
            }
        }
        return nil
    }
}

/// "Sürükleyerek yerleştirme": drag a window to a screen edge or corner, see a
/// preview, release to snap (Magnet / BetterSnapTool style).
///
/// Only mouse events are observed, and only while enabled. The dragged window
/// is identified on mouse-down; its frame is sampled at most every 60 ms.
@Observable
public final class DragSnapEngine: EventTapHandler {
    public static let shared = DragSnapEngine()

    public var isEnabled = false {
        didSet { EventTapManager.shared.refresh() }
    }
    public var configuration = DragSnapZones.Configuration()
    /// Hold this modifier while dragging to temporarily disable snapping.
    public var bypassModifier: KeyModifiers = .command
    public var excludedBundleIDs: Set<String> = []
    public var gap: CGFloat = 0

    /// Current preview target, in AX coordinates (nil when not hovering a zone).
    public private(set) var previewFrame: CGRect?
    public private(set) var previewPosition: SnapPosition?
    @ObservationIgnored public var onPreviewChange: (@MainActor (CGRect?, NSScreen?) -> Void)?

    @ObservationIgnored private var window: AXElement?
    @ObservationIgnored private var startFrame: CGRect?
    @ObservationIgnored private var isDraggingWindow = false
    @ObservationIgnored private var lastSample = Date.distantPast
    @ObservationIgnored private var previewScreen: NSScreen?

    public init() {}

    public var eventTapPriority: Int { 40 }

    public var eventTapTypes: Set<CGEventType> {
        isEnabled ? [.leftMouseDown, .leftMouseDragged, .leftMouseUp] : []
    }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        // Never block the tap with Accessibility IPC: identify and sample asynchronously.
        switch type {
        case .leftMouseDown:
            reset()
            let location = event.location
            DispatchQueue.main.async { [weak self] in self?.identifyWindow(at: location) }
        case .leftMouseDragged:
            guard window != nil else { return .pass }
            let point = ScreenGeometry.toCocoa(point: event.location)
            let modifiers = KeyModifiers(event.flags)
            if isDraggingWindow {
                updatePreview(at: point, modifiers: modifiers)
            } else if Date.now.timeIntervalSince(lastSample) > 0.06 {
                lastSample = .now
                DispatchQueue.main.async { [weak self] in self?.confirmMove(point: point, modifiers: modifiers) }
            }
        case .leftMouseUp:
            if isDraggingWindow, let window, let position = previewPosition, let screen = previewScreen {
                let target = window
                DispatchQueue.main.async {
                    WindowManager.shared.snap(target, to: position, on: screen)
                }
            }
            reset()
        default:
            break
        }
        return .pass
    }

    private func identifyWindow(at location: CGPoint) {
        guard let element = AXElement.element(at: location), let candidate = Self.window(containing: element),
              candidate.isStandardWindow, let pid = candidate.pid, pid != getpid(),
              !excludedBundleIDs.contains(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "") else { return }
        window = candidate
        startFrame = candidate.frame
    }

    /// A drag is a window move when the window's origin changes but not its size.
    private func confirmMove(point: CGPoint, modifiers: KeyModifiers) {
        guard let window, let startFrame, !isDraggingWindow, let frame = window.frame else { return }
        guard frame.size == startFrame.size, frame.origin != startFrame.origin else { return }
        isDraggingWindow = true
        updatePreview(at: point, modifiers: modifiers)
    }

    private func updatePreview(at point: CGPoint, modifiers: KeyModifiers) {
        guard !modifiers.contains(bypassModifier) || bypassModifier.isEmpty,
              let screen = NSScreen.screen(containing: point) else {
            setPreview(nil, nil, nil)
            return
        }
        guard let position = DragSnapZones.position(for: point, in: screen.frame, configuration: configuration) else {
            setPreview(nil, nil, nil)
            return
        }
        let area = ScreenGeometry.visibleFrameAX(of: screen)
        let frame = SnapGeometry.frame(for: position, in: area, gap: gap, current: startFrame)
        setPreview(position, frame, screen)
    }

    private func setPreview(_ position: SnapPosition?, _ frame: CGRect?, _ screen: NSScreen?) {
        guard position != previewPosition || screen != previewScreen else { return }
        previewPosition = position
        previewFrame = frame
        previewScreen = screen
        onPreviewChange?(frame, screen)
    }

    private func reset() {
        if previewPosition != nil { setPreview(nil, nil, nil) }
        window = nil
        startFrame = nil
        isDraggingWindow = false
        lastSample = .distantPast
    }

    /// Walks up from a hit-tested element to its window.
    private static func window(containing element: AXElement) -> AXElement? {
        if element.role == kAXWindowRole { return element }
        return element.element(kAXWindowAttribute)
    }
}
