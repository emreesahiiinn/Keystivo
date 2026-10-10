import AppKit
import CMultitouch
import KeystivoCore
import Observation

/// Recognizer state confined to the multitouch callback thread.
nonisolated final class MultitouchState: @unchecked Sendable {
    var recognizer = TrackpadRecognizer()
    var allowTwoFinger = false
    var points: [TouchPoint] = []
}

/// The multitouch C callback has no context pointer, so the live state is global.
nonisolated(unsafe) private var multitouchState: MultitouchState?

/// Receives raw trackpad contacts from the MultitouchSupport framework and
/// recognizes custom gestures. Devices are only started while at least one
/// trackpad binding is enabled, so the feature costs nothing when unused.
@Observable
public final class TrackpadGestureEngine {
    public static let shared = TrackpadGestureEngine()

    public private(set) var isRunning = false
    public private(set) var isAvailable = false
    /// Last recognized gesture (shown in Settings while recording a binding).
    public private(set) var lastGesture: TrackpadGesture?
    @ObservationIgnored public var onGesture: (@MainActor (TrackpadGesture) -> Void)?

    @ObservationIgnored private var devices: [KSMTDeviceRef] = []
    @ObservationIgnored private var deviceList: CFMutableArray?
    @ObservationIgnored private var flagsMonitor: Any?

    public init() {
        isAvailable = KSMTLoad()
    }

    public func setRunning(_ running: Bool) {
        running ? start() : stop()
    }

    private func start() {
        guard !isRunning, isAvailable, let unmanaged = KSMTCreateDeviceList() else { return }
        let list = unmanaged.takeRetainedValue()
        // Keep the list (and therefore its devices) alive while running.
        deviceList = list
        let state = MultitouchState()
        multitouchState = state
        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: pointer)
            KSMTRegister(device, multitouchCallback)
            KSMTStart(device)
            devices.append(device)
        }
        // Holding a modifier enables two-finger swipes without breaking normal scrolling.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            let modifiers = KeyModifiers(event.modifierFlags)
            multitouchState?.allowTwoFinger = !modifiers.intersection([.command, .option, .control]).isEmpty
        }
        isRunning = !devices.isEmpty
    }

    private func stop() {
        guard isRunning else { return }
        for device in devices {
            KSMTUnregister(device, multitouchCallback)
            KSMTStop(device)
        }
        devices.removeAll()
        deviceList = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        multitouchState = nil
        isRunning = false
    }

    nonisolated static func deliver(_ event: TrackpadRecognizer.Event) {
        let modifiers = KeyModifiers(CGEventSource.flagsState(.combinedSessionState))
        let gesture: TrackpadGesture = switch event {
        case .tap(let fingers): TrackpadGesture(kind: .tap, fingers: fingers, modifiers: modifiers)
        case .doubleTap(let fingers): TrackpadGesture(kind: .doubleTap, fingers: fingers, modifiers: modifiers)
        case .swipe(let fingers, let direction): TrackpadGesture(kind: .swipe, fingers: fingers, direction: direction, modifiers: modifiers)
        case .tipTap(let side): TrackpadGesture(kind: .tipTap, fingers: 2, direction: side, modifiers: modifiers)
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                TrackpadGestureEngine.shared.lastGesture = gesture
                TrackpadGestureEngine.shared.onGesture?(gesture)
            }
        }
    }
}

/// C-convention callback invoked ~100×/s on a private thread.
nonisolated private func multitouchCallback(_ device: KSMTDeviceRef?, _ touches: UnsafePointer<KSMTTouch>?, _ count: Int32, _ timestamp: Double, _ frame: Int32) -> Int32 {
    guard let state = multitouchState else { return 0 }
    state.points.removeAll(keepingCapacity: true)
    if let touches {
        for index in 0..<Int(count) {
            let touch = touches[index]
            // States 1…4 are touching; 5+ are lifting/hovering.
            if touch.state >= 1 && touch.state <= 4 {
                state.points.append(TouchPoint(id: touch.pathIndex, x: touch.normalized.position.x, y: touch.normalized.position.y))
            }
        }
    }
    for event in state.recognizer.process(state.points, timestamp: timestamp, allowTwoFingerSwipes: state.allowTwoFinger) {
        TrackpadGestureEngine.deliver(event)
    }
    return 0
}

// MARK: - Mouse gestures

/// Hold a mouse button and draw a stroke. Implemented on the shared event tap;
/// a plain click (no movement) is replayed so normal right-click still works.
@Observable
public final class MouseGestureEngine: EventTapHandler {
    public static let shared = MouseGestureEngine()

    public var isEnabled = false {
        didSet { EventTapManager.shared.refresh() }
    }
    public var button: MouseGestureButton = .right {
        didSet { EventTapManager.shared.refresh() }
    }
    public var excludedBundleIDs: Set<String> = []
    /// Live stroke for the on-screen trail (nil when idle).
    public private(set) var trail: [CGPoint]?
    public private(set) var currentStrokes = ""
    @ObservationIgnored public var onGesture: (@MainActor (MouseGesture) -> Void)?

    @ObservationIgnored private var recognizer = StrokeRecognizer()
    @ObservationIgnored private var downLocation: CGPoint?
    @ObservationIgnored private var tracking = false
    @ObservationIgnored private var gestureActive = false

    public init() {}

    public var eventTapPriority: Int { 50 }

    public var eventTapTypes: Set<CGEventType> {
        guard isEnabled else { return [] }
        return button == .right
            ? [.rightMouseDown, .rightMouseDragged, .rightMouseUp]
            : [.otherMouseDown, .otherMouseDragged, .otherMouseUp]
    }

    public func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        if button != .right, event.getIntegerValueField(.mouseEventButtonNumber) != button.buttonNumber {
            return .pass
        }
        switch type {
        case .rightMouseDown, .otherMouseDown:
            if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, excludedBundleIDs.contains(bundleID) {
                return .pass
            }
            tracking = true
            gestureActive = false
            downLocation = event.location
            recognizer.begin(at: event.location)
            return .consume
        case .rightMouseDragged, .otherMouseDragged:
            guard tracking else { return .pass }
            recognizer.add(event.location)
            if !gestureActive, recognizer.totalDistance > 12 {
                gestureActive = true
                trail = [downLocation ?? event.location]
            }
            if gestureActive {
                trail?.append(event.location)
                currentStrokes = recognizer.strokes
            }
            return .consume
        case .rightMouseUp, .otherMouseUp:
            guard tracking else { return .pass }
            tracking = false
            defer {
                trail = nil
                currentStrokes = ""
            }
            if gestureActive, !recognizer.strokes.isEmpty {
                let gesture = MouseGesture(button: button, strokes: recognizer.strokes)
                onGesture?(gesture)
                return .consume
            }
            // No gesture: replay the original click at its original location.
            if let location = downLocation {
                let replayButton: SyntheticInput.MouseButton = button == .right ? .right : .middle
                Task { SyntheticInput.click(at: location, button: replayButton) }
            }
            return .consume
        default:
            return .pass
        }
    }
}
