import CoreGraphics
import Foundation

/// One finger contact in normalized trackpad coordinates (0…1, origin bottom-left).
nonisolated public struct TouchPoint: Sendable, Equatable {
    public let id: Int32
    public let x: Float
    public let y: Float

    public init(id: Int32, x: Float, y: Float) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// Turns a stream of multitouch frames into discrete gestures. Pure state
/// machine (no I/O), driven from the multitouch callback thread.
nonisolated public struct TrackpadRecognizer: Sendable {
    public struct Configuration: Sendable {
        public var tapMaxDuration: TimeInterval = 0.22
        public var tapMaxMovement: Float = 0.035
        public var swipeMinDistance: Float = 0.13
        public var doubleTapWindow: TimeInterval = 0.32
        /// Minimum fingers for swipes without modifiers (2 would hijack scrolling).
        public var minimumSwipeFingers = 3
        public init() {}
    }

    public enum Event: Equatable, Sendable {
        case tap(fingers: Int)
        case doubleTap(fingers: Int)
        case swipe(fingers: Int, direction: GestureDirection)
        case tipTap(side: GestureDirection)
    }

    public var configuration: Configuration
    private var sequenceStart: TimeInterval?
    private var maxFingers = 0
    private var startCentroid: (Float, Float)?
    private var startFingerCount = 0
    private var maxMovement: Float = 0
    private var swipeFired = false
    private var lastTap: (fingers: Int, time: TimeInterval)?
    private var restingTouch: TouchPoint?
    private var restingStart: TimeInterval = 0
    private var tipCandidate: (side: GestureDirection, start: TimeInterval)?
    private var tipTapFired = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feed one frame. `allowTwoFingerSwipes` is true while a modifier is held.
    public mutating func process(_ touches: [TouchPoint], timestamp: TimeInterval, allowTwoFingerSwipes: Bool = false) -> [Event] {
        var events: [Event] = []
        if touches.isEmpty {
            if let start = sequenceStart {
                let duration = timestamp - start
                if !swipeFired, !tipTapFired, maxFingers >= 2, duration <= configuration.tapMaxDuration, maxMovement <= configuration.tapMaxMovement {
                    if let last = lastTap, last.fingers == maxFingers, timestamp - last.time <= configuration.doubleTapWindow {
                        events.append(.doubleTap(fingers: maxFingers))
                        lastTap = nil
                    } else {
                        events.append(.tap(fingers: maxFingers))
                        lastTap = (maxFingers, timestamp)
                    }
                }
            }
            reset()
            return events
        }

        if sequenceStart == nil {
            sequenceStart = timestamp
        }
        let centroid = Self.centroid(touches)
        detectTipTap(touches, timestamp: timestamp, into: &events)

        if touches.count != startFingerCount {
            // Finger count changed: re-anchor the centroid so swipe distance is measured
            // from when the final finger count was reached.
            startFingerCount = touches.count
            startCentroid = centroid
        }
        maxFingers = max(maxFingers, touches.count)
        if let start = startCentroid {
            let dx = centroid.0 - start.0
            let dy = centroid.1 - start.1
            maxMovement = max(maxMovement, (dx * dx + dy * dy).squareRoot())
            let minimum = allowTwoFingerSwipes ? 2 : configuration.minimumSwipeFingers
            if !swipeFired, touches.count >= minimum, max(abs(dx), abs(dy)) >= configuration.swipeMinDistance {
                swipeFired = true
                let direction: GestureDirection = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
                events.append(.swipe(fingers: touches.count, direction: direction))
            }
        }
        return events
    }

    /// Tip-tap: one finger resting (≥0.2 s), a second finger taps briefly beside it.
    private mutating func detectTipTap(_ touches: [TouchPoint], timestamp: TimeInterval, into events: inout [Event]) {
        switch touches.count {
        case 1:
            if let candidate = tipCandidate {
                if timestamp - candidate.start <= 0.25, restingTouch?.id == touches[0].id {
                    events.append(.tipTap(side: candidate.side))
                    tipTapFired = true
                }
                tipCandidate = nil
            }
            if restingTouch?.id != touches[0].id {
                restingTouch = touches[0]
                restingStart = timestamp
            }
        case 2:
            guard tipCandidate == nil, let resting = restingTouch, timestamp - restingStart >= 0.2,
                  let current = touches.first(where: { $0.id == resting.id }),
                  let other = touches.first(where: { $0.id != resting.id }) else { return }
            let drift = hypot(current.x - resting.x, current.y - resting.y)
            if drift < 0.02 { tipCandidate = (other.x < current.x ? .left : .right, timestamp) }
        default:
            tipCandidate = nil
            restingTouch = nil
        }
    }

    private mutating func reset() {
        sequenceStart = nil
        maxFingers = 0
        startCentroid = nil
        startFingerCount = 0
        maxMovement = 0
        swipeFired = false
        restingTouch = nil
        tipCandidate = nil
        tipTapFired = false
    }

    static func centroid(_ touches: [TouchPoint]) -> (Float, Float) {
        let count = Float(touches.count)
        return (touches.reduce(0) { $0 + $1.x } / count, touches.reduce(0) { $0 + $1.y } / count)
    }
}

/// Converts a mouse path into a stroke string such as "DR" (down, then right).
nonisolated public struct StrokeRecognizer: Sendable {
    public var minimumSegment: CGFloat
    private var anchor: CGPoint?
    public private(set) var directions: [GestureDirection] = []
    public private(set) var totalDistance: CGFloat = 0
    private var last: CGPoint?

    public init(minimumSegment: CGFloat = 28) {
        self.minimumSegment = minimumSegment
    }

    public var strokes: String { String(directions.map(\.letter)) }

    public mutating func begin(at point: CGPoint) {
        anchor = point
        last = point
        directions = []
        totalDistance = 0
    }

    /// Adds a point (screen coordinates, y grows downward as in Quartz).
    public mutating func add(_ point: CGPoint) {
        guard let anchor else { begin(at: point); return }
        if let last { totalDistance += hypot(point.x - last.x, point.y - last.y) }
        last = point
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        guard max(abs(dx), abs(dy)) >= minimumSegment else { return }
        let direction: GestureDirection = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
        if directions.last != direction { directions.append(direction) }
        self.anchor = point
    }
}
