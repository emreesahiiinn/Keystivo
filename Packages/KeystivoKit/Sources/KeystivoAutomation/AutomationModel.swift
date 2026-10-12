import Foundation
import KeystivoCore

nonisolated public enum PowerSourceKind: String, Codable, Hashable, Sendable, CaseIterable {
    case ac, battery, any
    public var titleKey: String { "power.source.\(rawValue)" }
}

/// What starts a workflow ("trigger-action sistemi").
nonisolated public enum TriggerSpec: Codable, Hashable, Sendable {
    /// Empty bundle ID matches any app.
    case appLaunched(bundleID: String)
    case appQuit(bundleID: String)
    case appActivated(bundleID: String)
    case appDeactivated(bundleID: String)
    case hotkey(KeyCombo)
    /// Weekdays use `Calendar` numbering (1 = Sunday); empty = every day.
    case schedule(hour: Int, minute: Int, weekdays: [Int])
    case interval(minutes: Int)
    case systemWake
    case systemSleep
    case screenLocked
    case screenUnlocked
    case displayConnected
    case displayDisconnected
    case powerSourceChanged(to: PowerSourceKind)
    case batteryBelow(percent: Int)
    case audioOutputChanged
    case inputDeviceConnected(match: String)
    case inputDeviceDisconnected(match: String)
    /// nil matches any profile.
    case profileActivated(UUID?)
    case focusStarted
    case focusEnded
    case keystivoLaunched
    /// Only runs when invoked from the launcher, menu bar or another workflow.
    case manual
    /// The text is typed anywhere (it's deleted before the workflow runs).
    case typedText(String)
    case clipboardChanged
    /// Empty matches any volume.
    case volumeMounted(match: String)
    case volumeUnmounted(match: String)
    /// Network connectivity or interface (Wi-Fi, Ethernet, VPN) changed.
    case networkChanged
    /// No keyboard or mouse input for this many minutes.
    case userIdle(minutes: Int)
    /// Input resumed after being idle.
    case userReturned
    /// Light/dark appearance switched.
    case appearanceChanged
    /// `keystivo://run/<name>` (Stream Deck, Shortcuts, scripts, other apps).
    case urlScheme(name: String)

    public var kind: String {
        switch self {
        case .appLaunched: "appLaunched"
        case .appQuit: "appQuit"
        case .appActivated: "appActivated"
        case .appDeactivated: "appDeactivated"
        case .hotkey: "hotkey"
        case .schedule: "schedule"
        case .interval: "interval"
        case .systemWake: "systemWake"
        case .systemSleep: "systemSleep"
        case .screenLocked: "screenLocked"
        case .screenUnlocked: "screenUnlocked"
        case .displayConnected: "displayConnected"
        case .displayDisconnected: "displayDisconnected"
        case .powerSourceChanged: "powerSourceChanged"
        case .batteryBelow: "batteryBelow"
        case .audioOutputChanged: "audioOutputChanged"
        case .inputDeviceConnected: "inputDeviceConnected"
        case .inputDeviceDisconnected: "inputDeviceDisconnected"
        case .profileActivated: "profileActivated"
        case .focusStarted: "focusStarted"
        case .focusEnded: "focusEnded"
        case .keystivoLaunched: "keystivoLaunched"
        case .manual: "manual"
        case .typedText: "typedText"
        case .clipboardChanged: "clipboardChanged"
        case .volumeMounted: "volumeMounted"
        case .volumeUnmounted: "volumeUnmounted"
        case .networkChanged: "networkChanged"
        case .userIdle: "userIdle"
        case .userReturned: "userReturned"
        case .appearanceChanged: "appearanceChanged"
        case .urlScheme: "urlScheme"
        }
    }

    public var titleKey: String { "trigger.\(kind)" }

    public var symbolName: String {
        switch self {
        case .appLaunched: "app.badge.checkmark"
        case .appQuit: "xmark.app"
        case .appActivated, .appDeactivated: "macwindow"
        case .hotkey: "command"
        case .schedule: "clock"
        case .interval: "timer"
        case .systemWake: "sun.max"
        case .systemSleep: "moon.zzz"
        case .screenLocked: "lock"
        case .screenUnlocked: "lock.open"
        case .displayConnected, .displayDisconnected: "display.2"
        case .powerSourceChanged: "powerplug"
        case .batteryBelow: "battery.25percent"
        case .audioOutputChanged: "hifispeaker"
        case .inputDeviceConnected, .inputDeviceDisconnected: "keyboard"
        case .profileActivated: "person.crop.circle"
        case .focusStarted, .focusEnded: "moon.circle"
        case .keystivoLaunched: "power"
        case .manual: "hand.tap"
        case .typedText: "character.cursor.ibeam"
        case .clipboardChanged: "clipboard"
        case .volumeMounted, .volumeUnmounted: "externaldrive"
        case .networkChanged: "network"
        case .userIdle: "zzz"
        case .userReturned: "figure.walk.arrival"
        case .appearanceChanged: "circle.lefthalf.filled"
        case .urlScheme: "link"
        }
    }

    /// Templates used by the "add trigger" menu.
    public static let templates: [TriggerSpec] = [
        .appLaunched(bundleID: ""), .appQuit(bundleID: ""), .appActivated(bundleID: ""), .appDeactivated(bundleID: ""),
        .hotkey(.unset), .schedule(hour: 9, minute: 0, weekdays: []), .interval(minutes: 30),
        .systemWake, .systemSleep, .screenLocked, .screenUnlocked, .displayConnected, .displayDisconnected,
        .powerSourceChanged(to: .battery), .batteryBelow(percent: 20), .audioOutputChanged,
        .inputDeviceConnected(match: ""), .inputDeviceDisconnected(match: ""), .profileActivated(nil),
        .focusStarted, .focusEnded, .keystivoLaunched, .manual,
        .typedText(""), .clipboardChanged, .volumeMounted(match: ""), .volumeUnmounted(match: ""), .networkChanged,
        .userIdle(minutes: 10), .userReturned, .appearanceChanged, .urlScheme(name: ""),
    ]

    /// Typed text that should trigger, if this is a typed-text trigger.
    public var typedText: String? {
        if case .typedText(let text) = self, !text.isEmpty { return text }
        return nil
    }
}

/// A runtime occurrence that may fire triggers.
nonisolated public enum AutomationEvent: Hashable, Sendable {
    case appLaunched(String)
    case appQuit(String)
    case appActivated(String)
    case appDeactivated(String)
    case hotkey(KeyCombo)
    case scheduleTick(Date)
    case interval(minutes: Int)
    case systemWake, systemSleep, screenLocked, screenUnlocked
    case displayConnected, displayDisconnected
    case powerSourceChanged(PowerSourceKind)
    case batteryLevel(Int, previous: Int?)
    case audioOutputChanged
    case inputDeviceConnected(String)
    case inputDeviceDisconnected(String)
    case profileActivated(UUID)
    case focusStarted, focusEnded
    case keystivoLaunched
    case typedText(String)
    case clipboardChanged
    case volumeMounted(String)
    case volumeUnmounted(String)
    case networkChanged
    /// Idle for this many whole minutes so far.
    case userIdle(minutes: Int)
    case userReturned
    case appearanceChanged
    case url(String)
}

nonisolated public extension TriggerSpec {
    /// Whether this trigger fires for an event. Pure; covered by unit tests.
    func matches(_ event: AutomationEvent, calendar: Calendar = .current) -> Bool {
        switch (self, event) {
        case (.appLaunched(let id), .appLaunched(let app)),
             (.appQuit(let id), .appQuit(let app)),
             (.appActivated(let id), .appActivated(let app)),
             (.appDeactivated(let id), .appDeactivated(let app)):
            return id.isEmpty || id == app
        case (.hotkey(let combo), .hotkey(let pressed)):
            return combo == pressed
        case (.schedule(let hour, let minute, let weekdays), .scheduleTick(let date)):
            let components = calendar.dateComponents([.hour, .minute, .weekday], from: date)
            return components.hour == hour && components.minute == minute
                && (weekdays.isEmpty || weekdays.contains(components.weekday ?? 0))
        case (.interval(let wanted), .interval(let minutes)):
            return wanted == minutes
        case (.systemWake, .systemWake), (.systemSleep, .systemSleep), (.screenLocked, .screenLocked),
             (.screenUnlocked, .screenUnlocked), (.displayConnected, .displayConnected),
             (.displayDisconnected, .displayDisconnected), (.audioOutputChanged, .audioOutputChanged),
             (.focusStarted, .focusStarted), (.focusEnded, .focusEnded), (.keystivoLaunched, .keystivoLaunched):
            return true
        case (.powerSourceChanged(let wanted), .powerSourceChanged(let source)):
            return wanted == .any || wanted == source
        case (.batteryBelow(let threshold), .batteryLevel(let level, let previous)):
            // Fire once when crossing the threshold downward.
            return level < threshold && (previous ?? 100) >= threshold
        case (.inputDeviceConnected(let match), .inputDeviceConnected(let name)),
             (.inputDeviceDisconnected(let match), .inputDeviceDisconnected(let name)):
            return match.isEmpty || name.localizedCaseInsensitiveContains(match)
        case (.profileActivated(let wanted), .profileActivated(let id)):
            return wanted == nil || wanted == id
        case (.typedText(let wanted), .typedText(let typed)):
            return !wanted.isEmpty && wanted == typed
        case (.clipboardChanged, .clipboardChanged), (.networkChanged, .networkChanged),
             (.userReturned, .userReturned), (.appearanceChanged, .appearanceChanged):
            return true
        case (.volumeMounted(let match), .volumeMounted(let name)),
             (.volumeUnmounted(let match), .volumeUnmounted(let name)):
            return match.isEmpty || name.localizedCaseInsensitiveContains(match)
        case (.userIdle(let wanted), .userIdle(let minutes)):
            // Fires once, at the minute the idle time reaches the threshold.
            return wanted == minutes
        case (.urlScheme(let wanted), .url(let name)):
            return !wanted.isEmpty && wanted.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        default:
            return false
        }
    }
}

// MARK: - Conditions

/// Extra requirements checked when a trigger fires ("koşullu otomasyonlar").
nonisolated public indirect enum ConditionSpec: Codable, Hashable, Sendable {
    case appRunning(bundleID: String)
    case appNotRunning(bundleID: String)
    case appFrontmost(bundleID: String)
    /// Minutes since midnight; wraps past midnight when start > end.
    case timeBetween(start: Int, end: Int)
    case weekdays([Int])
    case powerSource(PowerSourceKind)
    case batteryBelow(percent: Int)
    case batteryAbove(percent: Int)
    case displayCountAtLeast(Int)
    case profileActive(UUID)
    case audioOutput(deviceUID: String)
    case inputDeviceConnected(match: String)
    case focusActive(Bool)
    /// Workflow variables ({{name}}), set by earlier steps.
    case variableEquals(name: String, value: String)
    case variableContains(name: String, value: String)
    case variableNotEmpty(name: String)
    case all([ConditionSpec])
    case any([ConditionSpec])
    case not(ConditionSpec)

    public var kind: String {
        switch self {
        case .appRunning: "appRunning"
        case .appNotRunning: "appNotRunning"
        case .appFrontmost: "appFrontmost"
        case .timeBetween: "timeBetween"
        case .weekdays: "weekdays"
        case .powerSource: "powerSource"
        case .batteryBelow: "batteryBelow"
        case .batteryAbove: "batteryAbove"
        case .displayCountAtLeast: "displayCountAtLeast"
        case .profileActive: "profileActive"
        case .audioOutput: "audioOutput"
        case .inputDeviceConnected: "inputDeviceConnected"
        case .focusActive: "focusActive"
        case .variableEquals: "variableEquals"
        case .variableContains: "variableContains"
        case .variableNotEmpty: "variableNotEmpty"
        case .all: "all"
        case .any: "any"
        case .not: "not"
        }
    }

    public var titleKey: String { "condition.\(kind)" }

    public static let templates: [ConditionSpec] = [
        .appRunning(bundleID: ""), .appNotRunning(bundleID: ""), .appFrontmost(bundleID: ""),
        .timeBetween(start: 9 * 60, end: 18 * 60), .weekdays([2, 3, 4, 5, 6]), .powerSource(.battery),
        .batteryBelow(percent: 30), .batteryAbove(percent: 80), .displayCountAtLeast(2),
        .inputDeviceConnected(match: ""), .focusActive(true),
        .variableEquals(name: "output", value: ""), .variableContains(name: "output", value: ""), .variableNotEmpty(name: "output"),
    ]
}

/// The world as seen by conditions; real and mock implementations.
public protocol AutomationEnvironment {
    var now: Date { get }
    var calendar: Calendar { get }
    var frontmostBundleID: String? { get }
    func isRunning(_ bundleID: String) -> Bool
    var powerSource: PowerSourceKind { get }
    var batteryLevel: Int? { get }
    var displayCount: Int { get }
    var activeProfileID: UUID? { get }
    var audioOutputUID: String? { get }
    var connectedInputDeviceNames: [String] { get }
    var isFocusActive: Bool { get }
}

public enum ConditionEvaluator {
    public static func evaluate(_ condition: ConditionSpec, in environment: some AutomationEnvironment, variables: [String: String] = [:]) -> Bool {
        switch condition {
        case .variableEquals(let name, let value):
            return (variables[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .variableContains(let name, let value):
            return !value.isEmpty && (variables[name] ?? "").localizedCaseInsensitiveContains(value)
        case .variableNotEmpty(let name):
            return !(variables[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .appRunning(let id): return environment.isRunning(id)
        case .appNotRunning(let id): return !environment.isRunning(id)
        case .appFrontmost(let id): return environment.frontmostBundleID == id
        case .timeBetween(let start, let end):
            let components = environment.calendar.dateComponents([.hour, .minute], from: environment.now)
            let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            return start <= end ? (minutes >= start && minutes < end) : (minutes >= start || minutes < end)
        case .weekdays(let days):
            return days.contains(environment.calendar.component(.weekday, from: environment.now))
        case .powerSource(let source):
            return source == .any || environment.powerSource == source
        case .batteryBelow(let percent):
            return (environment.batteryLevel ?? 100) < percent
        case .batteryAbove(let percent):
            return (environment.batteryLevel ?? 0) > percent
        case .displayCountAtLeast(let count):
            return environment.displayCount >= count
        case .profileActive(let id):
            return environment.activeProfileID == id
        case .audioOutput(let uid):
            return environment.audioOutputUID == uid
        case .inputDeviceConnected(let match):
            return environment.connectedInputDeviceNames.contains { $0.localizedCaseInsensitiveContains(match) }
        case .focusActive(let active):
            return environment.isFocusActive == active
        case .all(let conditions):
            return conditions.allSatisfy { evaluate($0, in: environment, variables: variables) }
        case .any(let conditions):
            return conditions.isEmpty || conditions.contains { evaluate($0, in: environment, variables: variables) }
        case .not(let inner):
            return !evaluate(inner, in: environment, variables: variables)
        }
    }
}

// MARK: - Workflows

/// One step of a multi-step workflow ("çok adımlı workflow").
nonisolated public struct WorkflowStep: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var kind: Kind
    /// Disabled steps are skipped (handy while editing).
    public var isEnabled = true
    /// Keep going even if this step fails.
    public var continueOnError = false
    /// Saves the action's result (shell output, HTTP response…) as {{name}} too;
    /// it's always available as {{output}} until the next result.
    public var outputVariable: String?

    public indirect enum Kind: Codable, Hashable, Sendable {
        case action(ActionInvocation)
        case delay(seconds: Double)
        case condition(ConditionSpec, then: [WorkflowStep], otherwise: [WorkflowStep])
        case runWorkflow(UUID)
        case stop
        /// Sets {{name}}; the value may use other placeholders.
        case setVariable(name: String, value: String)
        /// Runs the steps `times` times; {{index}} is 1, 2, 3…
        case repeatTimes(Int, steps: [WorkflowStep])
        /// Pauses until the condition holds; fails after `timeout` seconds.
        case waitUntil(ConditionSpec, timeout: Double)
        /// Asks for text and stores it as {{variable}}; cancelling stops the workflow.
        case askInput(prompt: String, variable: String)
        /// Shows text in large type.
        case showText(String)
    }

    public init(_ kind: Kind) { self.kind = kind }

    public static func action(_ id: String, _ arguments: [String: ActionValue] = [:]) -> WorkflowStep {
        WorkflowStep(.action(ActionInvocation(id, arguments: arguments)))
    }
}

nonisolated public struct Workflow: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var symbolName = "bolt.fill"
    public var notes = ""
    public var isEnabled = true
    public var triggers: [TriggerSpec]
    public var condition: ConditionSpec?
    public var steps: [WorkflowStep]
    /// Profiles where the workflow is active (empty = all profiles).
    public var profileIDs: [UUID] = []
    /// Skip a trigger while a previous run is still in progress.
    public var preventsOverlap = true
    public var showsInLauncher = true

    public init(name: String, triggers: [TriggerSpec], condition: ConditionSpec? = nil, steps: [WorkflowStep]) {
        self.name = name
        self.triggers = triggers
        self.condition = condition
        self.steps = steps
    }

    public var hotkeys: [KeyCombo] {
        triggers.compactMap { if case .hotkey(let combo) = $0 { combo } else { nil } }
    }
}
