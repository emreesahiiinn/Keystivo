import AppKit
import KeystivoCore

nonisolated public struct BrowserInfo: Identifiable, Hashable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let url: URL
}

/// Sends links to a specific browser by host and/or source app.
nonisolated public struct LinkRule: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    /// Host pattern: "github.com" matches the domain and its subdomains; "*" wildcards allowed.
    public var hostPattern: String
    /// Only links opened from this app (e.g. Slack), or nil for any.
    public var sourceBundleID: String?
    public var browserBundleID: String
    public var isEnabled = true

    public init(hostPattern: String, sourceBundleID: String? = nil, browserBundleID: String) {
        self.hostPattern = hostPattern
        self.sourceBundleID = sourceBundleID
        self.browserBundleID = browserBundleID
    }
}

nonisolated public struct LinkSettings: Codable, Hashable, Sendable {
    public enum Fallback: String, Codable, Sendable, CaseIterable {
        /// Show the browser picker.
        case ask
        /// Open in `defaultBrowserBundleID`.
        case defaultBrowser
        public var titleKey: String { "links.fallback.\(rawValue)" }
    }

    public var isEnabled = false
    public var fallback: Fallback = .defaultBrowser
    public var defaultBrowserBundleID: String?
    public var rules: [LinkRule] = []
    public var stripsTrackingParameters = true
    /// Hold ⌥ while clicking a link to always show the picker.
    public var optionShowsPicker = true
    public init() {}
}

/// Link routing ("Velja / Choosy / OpenIn"). Keystivo registers as a browser;
/// every link is matched against rules and forwarded to the right browser.
public enum LinkRouter {
    public enum Decision: Equatable, Sendable {
        case open(String)
        case ask
    }

    /// Installed apps that can open https links, excluding Keystivo.
    public static func installedBrowsers() -> [BrowserInfo] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return BrowserInfo(bundleID: id, name: name, url: url)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Host glob matching: "example.com" also matches "www.example.com".
    nonisolated public static func hostMatches(_ pattern: String, host: String) -> Bool {
        let pattern = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        let host = host.lowercased()
        guard !pattern.isEmpty else { return false }
        if pattern.contains("*") { return fnmatch(pattern, host, 0) == 0 }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    nonisolated public static func resolve(_ url: URL, sourceBundleID: String?, settings: LinkSettings, forcePicker: Bool = false) -> Decision {
        if forcePicker { return .ask }
        let host = url.host() ?? ""
        let candidates = settings.rules.filter(\.isEnabled)
        // Rules with a source app are more specific and win.
        if let match = candidates.first(where: { $0.sourceBundleID != nil && $0.sourceBundleID == sourceBundleID && (rulePatternIsAny($0) || hostMatches($0.hostPattern, host: host)) }) {
            return .open(match.browserBundleID)
        }
        if let match = candidates.first(where: { $0.sourceBundleID == nil && hostMatches($0.hostPattern, host: host) }) {
            return .open(match.browserBundleID)
        }
        switch settings.fallback {
        case .ask: return .ask
        case .defaultBrowser: return settings.defaultBrowserBundleID.map(Decision.open) ?? .ask
        }
    }

    nonisolated static func rulePatternIsAny(_ rule: LinkRule) -> Bool {
        rule.hostPattern.isEmpty || rule.hostPattern == "*"
    }

    nonisolated static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid", "_hsenc", "_hsmi",
        "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "si", "ref_src",
    ]

    /// Removes utm_* and well-known click-tracking parameters.
    nonisolated public static func clean(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = components.queryItems else { return url }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count != items.count else { return url }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    public static func open(_ url: URL, inBrowser bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
    }

    public static var isDefaultBrowser: Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Asks macOS to make Keystivo the default browser (the system shows a confirmation).
    public static func becomeDefaultBrowser() async throws {
        let app = Bundle.main.bundleURL
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
    }
}
