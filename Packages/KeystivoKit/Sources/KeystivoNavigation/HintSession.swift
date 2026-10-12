import AppKit
import KeystivoAccessibility
import KeystivoCore

/// How a selected hint is activated. Chosen by the modifier held while typing
/// the last character of a label.
nonisolated public enum HintActivation: String, Codable, Sendable, CaseIterable {
    case click, rightClick, doubleClick, commandClick, moveMouse

    public init(modifiers: KeyModifiers) {
        if modifiers.contains(.shift) { self = .rightClick }
        else if modifiers.contains(.command) { self = .commandClick }
        else if modifiers.contains(.option) { self = .doubleClick }
        else if modifiers.contains(.control) { self = .moveMouse }
        else { self = .click }
    }
}

/// Pure state machine for label typing and text search. No UI, fully testable.
nonisolated public struct HintMatcher: Sendable {
    public enum Mode: Sendable { case labels, search }

    public enum Outcome: Equatable, Sendable {
        /// Still ambiguous; `visible` are indices of candidates to keep showing.
        case pending(visible: [Int])
        case matched(Int)
        case noMatch
    }

    public let labels: [String]
    public let titles: [String]
    public private(set) var typed = ""
    public private(set) var mode: Mode = .labels
    /// Selected index within the current search results.
    public private(set) var searchSelection = 0

    public init(labels: [String], titles: [String]) {
        self.labels = labels.map { $0.lowercased() }
        self.titles = titles
    }

    public mutating func setMode(_ mode: Mode) {
        self.mode = mode
        typed = ""
        searchSelection = 0
    }

    public mutating func type(_ character: Character) -> Outcome {
        typed.append(Character(character.lowercased()))
        // A new query starts at its best match.
        searchSelection = 0
        return evaluate()
    }

    public mutating func backspace() -> Outcome {
        if !typed.isEmpty { typed.removeLast() }
        searchSelection = 0
        return evaluate()
    }

    /// Whether a typed character belongs in a query. Function keys (arrows,
    /// Home, F1…) report private-use characters that must be ignored.
    public static func isTypable(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        if scalar.properties.generalCategory == .control { return false }
        return true
    }

    public mutating func moveSelection(by delta: Int) -> Outcome {
        guard mode == .search else { return evaluate() }
        let results = searchResults()
        guard !results.isEmpty else { return .noMatch }
        searchSelection = (searchSelection + delta + results.count) % results.count
        return .pending(visible: results)
    }

    /// Confirms the current search selection (Return in search mode).
    public func confirm() -> Outcome {
        switch mode {
        case .labels:
            if let index = labels.firstIndex(of: typed) { return .matched(index) }
            return .noMatch
        case .search:
            let results = searchResults()
            guard results.indices.contains(searchSelection) else { return .noMatch }
            return .matched(results[searchSelection])
        }
    }

    public func evaluate() -> Outcome {
        switch mode {
        case .labels:
            if typed.isEmpty { return .pending(visible: Array(labels.indices)) }
            let candidates = labels.indices.filter { labels[$0].hasPrefix(typed) }
            if candidates.count == 1, labels[candidates[0]] == typed { return .matched(candidates[0]) }
            return candidates.isEmpty ? .noMatch : .pending(visible: candidates)
        case .search:
            let results = searchResults()
            if results.isEmpty { return typed.isEmpty ? .pending(visible: []) : .noMatch }
            return .pending(visible: results)
        }
    }

    /// Indices whose title matches the typed text, best first.
    public func searchResults() -> [Int] {
        guard !typed.isEmpty else { return Array(titles.indices.filter { !titles[$0].isEmpty }) }
        return titles.indices
            .compactMap { index -> (Int, Double)? in
                guard let match = FuzzyMatcher.match(typed, in: titles[index]) else { return nil }
                return (index, match.score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// Performs the physical action for a chosen element.
public enum HintActuator {
    public static func activate(_ element: NavigableElement, with activation: HintActivation) {
        let point = element.center
        switch activation {
        case .click:
            // Prefer AXPress for buttons/links: no cursor movement, works when occluded.
            let pressable: Set<String> = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuItemRole, kAXMenuBarItemRole, "AXLink", kAXDisclosureTriangleRole, "AXDockItem"]
            if element.canPress, pressable.contains(element.role), element.element.press() {
                return
            }
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(element.role) {
                element.element.set(kAXFocusedAttribute, kCFBooleanTrue)
            }
            SyntheticInput.click(at: point)
        case .rightClick:
            if element.element.actionNames.contains(kAXShowMenuAction), element.element.perform(kAXShowMenuAction) { return }
            SyntheticInput.click(at: point, button: .right)
        case .doubleClick:
            SyntheticInput.click(at: point, clickCount: 2)
        case .commandClick:
            SyntheticInput.click(at: point, modifiers: .command)
        case .moveMouse:
            SyntheticInput.moveMouse(to: point)
        }
    }
}

/// Keyboard scrolling over a chosen scroll area.
public enum ScrollActuator {
    public enum Direction: Sendable { case up, down, left, right, pageUp, pageDown, top, bottom }

    public static func focus(_ area: NavigableElement) {
        CGWarpMouseCursorPosition(area.center)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public static func scroll(_ direction: Direction, in area: NavigableElement, step: Int32 = 60) {
        let page = Int32(clamping: (area.frame.height * 0.8).safeInt)
        let (dx, dy): (Int32, Int32) = switch direction {
        case .up: (0, step)
        case .down: (0, -step)
        case .left: (step, 0)
        case .right: (-step, 0)
        case .pageUp: (0, page)
        case .pageDown: (0, -page)
        case .top: (0, 100_000)
        case .bottom: (0, -100_000)
        }
        SyntheticInput.scroll(dx: dx, dy: dy, at: area.center)
    }
}
