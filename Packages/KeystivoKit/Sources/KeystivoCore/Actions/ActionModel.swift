import Foundation

/// A typed, Codable argument value for an action.
nonisolated public enum ActionValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case keyCombo(KeyCombo)
    case strings([String])

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.formatted()
        case .bool(let value): value ? "true" : "false"
        case .strings(let value): value.joined(separator: ", ")
        case .keyCombo: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "yes", "1", "on"].contains(value.lowercased())
        default: nil
        }
    }
}

/// A reference to a registered action plus its arguments. This is the unit that
/// shortcuts, gestures, workflows, the launcher and plugins all share.
nonisolated public struct ActionInvocation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var actionID: String
    public var arguments: [String: ActionValue]

    public init(_ actionID: String, arguments: [String: ActionValue] = [:], id: UUID = UUID()) {
        self.id = id
        self.actionID = actionID
        self.arguments = arguments
    }
}

/// Convenience accessors used by action handlers.
nonisolated public struct ActionArguments: Sendable {
    public let values: [String: ActionValue]
    public init(_ values: [String: ActionValue]) { self.values = values }

    public func string(_ key: String) -> String? { values[key]?.stringValue }
    public func double(_ key: String) -> Double? { values[key]?.doubleValue }
    public func int(_ key: String) -> Int? { values[key]?.doubleValue.map { Int($0) } }
    public func bool(_ key: String) -> Bool? { values[key]?.boolValue }
    public func strings(_ key: String) -> [String] {
        if case .strings(let list) = values[key] { return list }
        return values[key]?.stringValue.map { [$0] } ?? []
    }
    public func combo(_ key: String) -> KeyCombo? {
        if case .keyCombo(let combo) = values[key] { return combo }
        return nil
    }

    public func require(_ key: String) throws(ActionError) -> String {
        guard let value = string(key), !value.isEmpty else { throw .missingArgument(key) }
        return value
    }
}

nonisolated public enum ActionCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case windows, apps, audio, navigation, clipboard, launcher, workspace, automation, input, system, power, plugins

    public var id: String { rawValue }
    public var titleKey: String { "category.\(rawValue)" }

    public var symbolName: String {
        switch self {
        case .windows: "macwindow.on.rectangle"
        case .apps: "app.badge"
        case .audio: "speaker.wave.2"
        case .navigation: "keyboard"
        case .clipboard: "doc.on.clipboard"
        case .launcher: "magnifyingglass"
        case .workspace: "rectangle.3.group"
        case .automation: "bolt.horizontal"
        case .input: "hand.point.up.left"
        case .system: "gearshape"
        case .power: "battery.75percent"
        case .plugins: "puzzlepiece.extension"
        }
    }
}

/// One choice inside a `.choice` parameter.
nonisolated public struct ChoiceOption: Hashable, Sendable, Identifiable {
    public let value: String
    public let titleKey: String
    public var id: String { value }
    public init(_ value: String, _ titleKey: String) {
        self.value = value
        self.titleKey = titleKey
    }
}

/// Describes how a parameter is edited in the workflow/shortcut editors.
nonisolated public enum ParameterKind: Hashable, Sendable {
    case text
    case multilineText
    case number(min: Double, max: Double, step: Double)
    case toggle
    case choice([ChoiceOption])
    /// Choices resolved at edit time by a named provider (devices, workflows…).
    case dynamicChoice(String)
    case application
    case keyCombo
    case filePath
    case url
}

nonisolated public struct ParameterSpec: Identifiable, Hashable, Sendable {
    public let key: String
    public let titleKey: String
    public let kind: ParameterKind
    public let defaultValue: ActionValue?
    public let isOptional: Bool

    public var id: String { key }

    public init(_ key: String, _ titleKey: String, _ kind: ParameterKind, default defaultValue: ActionValue? = nil, optional: Bool = false) {
        self.key = key
        self.titleKey = titleKey
        self.kind = kind
        self.defaultValue = defaultValue
        self.isOptional = optional
    }
}

nonisolated public struct ActionDescriptor: Identifiable, Sendable {
    public let id: String
    public let titleKey: String
    public let symbolName: String
    public let category: ActionCategory
    public let parameters: [ParameterSpec]
    /// Extra search terms (always English; localized titles are matched too).
    public let keywords: [String]
    /// Ask before running from the launcher (e.g. shut down).
    public let requiresConfirmation: Bool
    /// Shown as a standalone command in the launcher when it needs no input.
    public let showsInLauncher: Bool

    public init(
        id: String,
        titleKey: String,
        symbol: String,
        category: ActionCategory,
        parameters: [ParameterSpec] = [],
        keywords: [String] = [],
        requiresConfirmation: Bool = false,
        showsInLauncher: Bool = true
    ) {
        self.id = id
        self.titleKey = titleKey
        self.symbolName = symbol
        self.category = category
        self.parameters = parameters
        self.keywords = keywords
        self.requiresConfirmation = requiresConfirmation
        self.showsInLauncher = showsInLauncher
    }

    /// True when every parameter has a default or is optional.
    public var isRunnableWithoutInput: Bool {
        parameters.allSatisfy { $0.defaultValue != nil || $0.isOptional }
    }

    public func defaultInvocation() -> ActionInvocation {
        var arguments: [String: ActionValue] = [:]
        for parameter in parameters {
            if let value = parameter.defaultValue { arguments[parameter.key] = value }
        }
        return ActionInvocation(id, arguments: arguments)
    }
}

/// Context passed to handlers: where the action came from and any variables
/// produced by earlier steps of a chain or workflow.
nonisolated public struct ActionContext: Sendable {
    public enum Source: String, Sendable { case hotkey, gesture, launcher, workflow, menuBar, plugin, automation, test }

    public var source: Source
    public var targetBundleID: String?
    public var variables: [String: String]
    /// Where an action's text result goes (workflows pass it to later steps).
    public var output: ActionOutputSink?

    public init(source: Source, targetBundleID: String? = nil, variables: [String: String] = [:], output: ActionOutputSink? = nil) {
        self.source = source
        self.targetBundleID = targetBundleID
        self.variables = variables
        self.output = output
    }

    /// Reports the action's result (shell output, HTTP response, transformed text…).
    public func emit(_ text: String) { output?.set(text) }
}

/// Collects an action's text result.
nonisolated public final class ActionOutputSink: @unchecked Sendable {
    private var value: String?
    private let lock = NSLock()

    public init() {}

    public func set(_ text: String) { lock.withLock { value = text } }
    public var text: String? { lock.withLock { value } }
}

nonisolated public enum ActionError: LocalizedError, Equatable {
    case unknownAction(String)
    case missingArgument(String)
    case permissionRequired(PermissionKind)
    case notAvailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let id): L("action.error.unknown", id)
        case .missingArgument(let key): L("action.error.missingArgument", key)
        case .permissionRequired(let kind): L("action.error.permission", L(kind.titleKey))
        case .notAvailable(let reason): reason
        case .failed(let message): message
        }
    }
}
