import AppKit
import KeystivoCore

/// `{{name}}` placeholders in workflow steps: workflow variables plus a few live
/// values ({{clipboard}}, {{frontApp}}, {{date}}…). Unknown names expand to "".
nonisolated public enum Placeholders {
    /// Live values, computed only when a text actually uses them.
    @MainActor static func builtIn(_ name: String) -> String? {
        switch name {
        case "clipboard": NSPasteboard.general.string(forType: .string) ?? ""
        case "frontApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        case "frontAppID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        case "date": Date.now.formatted(date: .abbreviated, time: .omitted)
        case "time": Date.now.formatted(date: .omitted, time: .shortened)
        case "isoDate": Date.now.formatted(.iso8601.year().month().day())
        case "timestamp": String(Int(Date.now.timeIntervalSince1970))
        case "uuid": UUID().uuidString
        default: nil
        }
    }

    /// Replaces every `{{name}}` in `text`.
    @MainActor public static func expand(_ text: String, variables: [String: String]) -> String {
        guard text.contains("{{") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            result += variables[name] ?? builtIn(name) ?? ""
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    /// The invocation with placeholders filled in its text arguments.
    @MainActor public static func expand(_ invocation: ActionInvocation, variables: [String: String]) -> ActionInvocation {
        var copy = invocation
        for (key, value) in invocation.arguments {
            switch value {
            case .string(let text): copy.arguments[key] = .string(expand(text, variables: variables))
            case .strings(let list): copy.arguments[key] = .strings(list.map { expand($0, variables: variables) })
            default: break
            }
        }
        return copy
    }
}
