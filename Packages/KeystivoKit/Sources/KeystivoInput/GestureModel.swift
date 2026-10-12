import Foundation
import KeystivoCore

nonisolated public enum GestureDirection: String, Codable, Sendable, CaseIterable {
    case up, down, left, right

    public var symbol: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }

    public var letter: Character {
        switch self {
        case .up: "U"
        case .down: "D"
        case .left: "L"
        case .right: "R"
        }
    }

    public init?(letter: Character) {
        switch letter {
        case "U": self = .up
        case "D": self = .down
        case "L": self = .left
        case "R": self = .right
        default: return nil
        }
    }
}

/// A trackpad gesture Keystivo can recognize.
nonisolated public struct TrackpadGesture: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case tap
        case doubleTap
        case swipe
        /// One finger resting, another tapping on its left/right side.
        case tipTap
    }

    public var kind: Kind
    public var fingers: Int
    public var direction: GestureDirection?
    /// Keys that must be held (lets two-finger swipes coexist with scrolling).
    public var modifiers: KeyModifiers

    public init(kind: Kind, fingers: Int, direction: GestureDirection? = nil, modifiers: KeyModifiers = []) {
        self.kind = kind
        self.fingers = fingers
        self.direction = direction
        self.modifiers = modifiers
    }

    public var displayString: String {
        var text = modifiers.isEmpty ? "" : modifiers.symbols + " "
        switch kind {
        case .tap: text += L("gesture.display.tap", fingers)
        case .doubleTap: text += L("gesture.display.doubleTap", fingers)
        case .swipe: text += L("gesture.display.swipe", fingers, direction?.symbol ?? "")
        case .tipTap: text += L("gesture.display.tipTap", direction?.symbol ?? "")
        }
        return text
    }
}

nonisolated public enum MouseGestureButton: String, Codable, Sendable, CaseIterable {
    case right, middle, button4, button5

    public var titleKey: String { "mouseButton.\(rawValue)" }

    /// CGEvent button number.
    public var buttonNumber: Int64 {
        switch self {
        case .right: 1
        case .middle: 2
        case .button4: 3
        case .button5: 4
        }
    }
}

/// A mouse stroke: hold a button and draw directions, e.g. "LR" or "DR".
nonisolated public struct MouseGesture: Codable, Hashable, Sendable {
    public var button: MouseGestureButton
    public var strokes: String

    public init(button: MouseGestureButton = .right, strokes: String) {
        self.button = button
        self.strokes = strokes.uppercased()
    }

    public var directions: [GestureDirection] { strokes.compactMap(GestureDirection.init(letter:)) }
    public var displayString: String { directions.map(\.symbol).joined() }
}

/// What triggers a binding.
nonisolated public enum GestureTrigger: Codable, Hashable, Sendable {
    case trackpad(TrackpadGesture)
    case mouse(MouseGesture)

    public var displayString: String {
        switch self {
        case .trackpad(let gesture): gesture.displayString
        case .mouse(let gesture): "🖱 " + gesture.displayString
        }
    }

    /// Mouse gestures all use the one gesture button, so only their strokes count.
    public func matches(_ other: GestureTrigger) -> Bool {
        switch (self, other) {
        case (.mouse(let lhs), .mouse(let rhs)): lhs.strokes == rhs.strokes
        default: self == other
        }
    }
}

/// Gesture → action chain, optionally limited to some apps ("uygulamaya özel gesture profilleri").
nonisolated public struct GestureBinding: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var trigger: GestureTrigger
    public var actions: [ActionInvocation]
    /// Empty = everywhere. Otherwise only when one of these apps is frontmost.
    public var appBundleIDs: [String] = []
    /// Profiles in which this binding is active (empty = all).
    public var profileIDs: [UUID] = []
    public var isEnabled = true

    public init(trigger: GestureTrigger, actions: [ActionInvocation], appBundleIDs: [String] = []) {
        self.trigger = trigger
        self.actions = actions
        self.appBundleIDs = appBundleIDs
    }

    public var isAppSpecific: Bool { !appBundleIDs.isEmpty }
}

/// Picks the binding to run for a trigger: app-specific bindings take
/// precedence over global ones (gesture conflict priority rule).
nonisolated public enum GestureResolver {
    public static func resolve(_ trigger: GestureTrigger, in bindings: [GestureBinding], frontmostBundleID: String?, profileID: UUID?) -> GestureBinding? {
        let candidates = bindings.filter { binding in
            binding.isEnabled && binding.trigger.matches(trigger)
                && (binding.profileIDs.isEmpty || profileID.map(binding.profileIDs.contains) == true)
        }
        if let bundleID = frontmostBundleID,
           let specific = candidates.first(where: { $0.appBundleIDs.contains(bundleID) }) {
            return specific
        }
        return candidates.first { !$0.isAppSpecific }
    }
}
