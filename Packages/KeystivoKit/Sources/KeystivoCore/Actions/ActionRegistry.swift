import Foundation
import Observation

public typealias ActionHandler = @MainActor (ActionArguments, ActionContext) async throws -> Void

/// Central catalog of everything Keystivo can *do*. Feature modules register
/// their actions at startup; every trigger surface (shortcuts, gestures,
/// launcher, workflows, plugins) executes through here.
@Observable
public final class ActionRegistry {
    public static let shared = ActionRegistry()

    public private(set) var descriptors: [String: ActionDescriptor] = [:]
    @ObservationIgnored private var handlers: [String: ActionHandler] = [:]
    /// Resolves `.dynamicChoice` parameter options for editors.
    @ObservationIgnored public var choiceProviders: [String: @MainActor () -> [ChoiceOption]] = [:]
    /// Called after each action (for history, diagnostics, analytics-free stats).
    @ObservationIgnored public var onPerform: (@MainActor (ActionInvocation, ActionContext, (any Error)?) -> Void)?

    public init() {}

    public func register(_ descriptor: ActionDescriptor, handler: @escaping ActionHandler) {
        descriptors[descriptor.id] = descriptor
        handlers[descriptor.id] = handler
    }

    public func unregister(_ id: String) {
        descriptors[id] = nil
        handlers[id] = nil
    }

    public func unregister(prefix: String) {
        for id in descriptors.keys where id.hasPrefix(prefix) { unregister(id) }
    }

    public func descriptor(_ id: String) -> ActionDescriptor? { descriptors[id] }

    public var sortedDescriptors: [ActionDescriptor] {
        descriptors.values.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return ActionCategory.allCases.firstIndex(of: lhs.category)! < ActionCategory.allCases.firstIndex(of: rhs.category)!
            }
            return L(lhs.titleKey).localizedStandardCompare(L(rhs.titleKey)) == .orderedAscending
        }
    }

    public func descriptors(in category: ActionCategory) -> [ActionDescriptor] {
        sortedDescriptors.filter { $0.category == category }
    }

    public func options(for provider: String) -> [ChoiceOption] {
        choiceProviders[provider]?() ?? []
    }

    /// Executes one action. Errors are rethrown and also reported to diagnostics.
    public func perform(_ invocation: ActionInvocation, context: ActionContext) async throws {
        guard let handler = handlers[invocation.actionID] else {
            let error = ActionError.unknownAction(invocation.actionID)
            onPerform?(invocation, context, error)
            throw error
        }
        let arguments = ActionArguments(mergedArguments(for: invocation))
        do {
            try await handler(arguments, context)
            onPerform?(invocation, context, nil)
        } catch {
            onPerform?(invocation, context, error)
            DiagnosticsCenter.shared.record(error, module: "Actions", context: title(for: invocation))
            throw error
        }
    }

    /// Runs a command chain in order; stops at the first failure.
    public func perform(chain: [ActionInvocation], context: ActionContext) async throws {
        for invocation in chain {
            try Task.checkCancellation()
            try await perform(invocation, context: context)
        }
    }

    /// Fire-and-forget variant for UI callbacks.
    public func run(_ invocation: ActionInvocation, source: ActionContext.Source) {
        Task { try? await perform(invocation, context: ActionContext(source: source)) }
    }

    public func run(chain: [ActionInvocation], source: ActionContext.Source) {
        Task { try? await perform(chain: chain, context: ActionContext(source: source)) }
    }

    private func mergedArguments(for invocation: ActionInvocation) -> [String: ActionValue] {
        var values = invocation.arguments
        if let descriptor = descriptors[invocation.actionID] {
            for parameter in descriptor.parameters where values[parameter.key] == nil {
                if let value = parameter.defaultValue { values[parameter.key] = value }
            }
        }
        return values
    }

    /// Human-readable title including the most relevant argument.
    public func title(for invocation: ActionInvocation) -> String {
        guard let descriptor = descriptors[invocation.actionID] else { return invocation.actionID }
        let base = L(descriptor.titleKey)
        guard let parameter = descriptor.parameters.first, let value = invocation.arguments[parameter.key] else { return base }
        let detail: String? = switch parameter.kind {
        case .choice(let options):
            options.first { $0.value == value.stringValue }.map { L($0.titleKey) }
        case .dynamicChoice(let provider):
            options(for: provider).first { $0.value == value.stringValue }.map { L($0.titleKey) } ?? value.stringValue
        case .application:
            value.stringValue.flatMap(AppDisplayName.name(forBundleID:))
        case .keyCombo:
            if case .keyCombo(let combo) = value { combo.displayString } else { nil }
        case .toggle:
            nil
        default:
            value.stringValue
        }
        guard let detail, !detail.isEmpty else { return base }
        return "\(base) — \(detail)"
    }
}
