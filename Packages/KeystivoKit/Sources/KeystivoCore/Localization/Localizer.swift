import Foundation
import Observation

/// Thread-safe, live-switchable string lookup.
///
/// The interface language can change at runtime without relaunching. SwiftUI views
/// that call ``L(_:)`` while rendering automatically re-render when the language
/// changes, because every lookup registers an Observation access.
public nonisolated final class Localizer: Observable, @unchecked Sendable {
    public static let shared = Localizer()

    private struct State {
        var preference: String
        var code: String
        var locale: Locale
        var bundle: Bundle?
        var fallback: Bundle?
        var revision: Int
    }

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var state: State
    private let resourceBundle: Bundle

    /// Missing-key sentinel; never a legitimate translation.
    private static let missing = "\u{1}__missing__"

    public init(resourceBundle: Bundle? = nil, preference: String = AppLanguage.systemCode) {
        let resourceBundle = resourceBundle ?? Self.locateResourceBundle()
        self.resourceBundle = resourceBundle
        let fallback = Self.lprojBundle(code: "en", in: resourceBundle)
        state = State(
            preference: preference,
            code: "en",
            locale: Locale(identifier: "en"),
            bundle: fallback,
            fallback: fallback,
            revision: 0
        )
        apply(preference: preference)
    }

    // MARK: Observation

    /// Observed token; reading it ties a view to language changes.
    public var revision: Int {
        registrar.access(self, keyPath: \.revision)
        return lock.withLock { state.revision }
    }

    /// The user's stored preference (`"system"` or a language code).
    public var preference: String {
        registrar.access(self, keyPath: \.revision)
        return lock.withLock { state.preference }
    }

    /// The resolved language code in use.
    public var languageCode: String {
        registrar.access(self, keyPath: \.revision)
        return lock.withLock { state.code }
    }

    /// Locale matching the active language, for number/date formatting.
    public var locale: Locale {
        registrar.access(self, keyPath: \.revision)
        return lock.withLock { state.locale }
    }

    // MARK: Switching

    public func setPreference(_ preference: String) {
        registrar.withMutation(of: self, keyPath: \.revision) {
            apply(preference: preference)
        }
    }

    private func apply(preference: String) {
        let code = preference == AppLanguage.systemCode
            ? AppLanguage.resolve()
            : (AppLanguage.supportedCodes.contains(preference) ? preference : "en")
        let bundle = Self.lprojBundle(code: code, in: resourceBundle)
        lock.withLock {
            state.preference = preference
            state.code = code
            state.locale = Locale(identifier: code)
            state.bundle = bundle ?? state.fallback
            state.revision &+= 1
        }
    }

    private final class BundleMarker {}

    /// Finds the package resource bundle without touching the generated (main-actor
    /// isolated) `Bundle.module` accessor, so lookups work from any thread.
    private static func locateResourceBundle() -> Bundle {
        let name = "KeystivoKit_KeystivoCore.bundle"
        let codeBundle = Bundle(for: BundleMarker.self)
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            codeBundle.resourceURL,
            codeBundle.bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]
        for case let directory? in candidates {
            if let bundle = Bundle(url: directory.appendingPathComponent(name)) { return bundle }
        }
        return .main
    }

    private static func lprojBundle(code: String, in bundle: Bundle) -> Bundle? {
        let candidates = [code, code.lowercased(), code.replacingOccurrences(of: "-", with: "_")]
        for candidate in candidates {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"), let lproj = Bundle(path: path) {
                return lproj
            }
        }
        return nil
    }

    // MARK: Lookup

    public func string(_ key: String) -> String {
        registrar.access(self, keyPath: \.revision)
        let (bundle, fallback) = lock.withLock { (state.bundle, state.fallback) }
        if let value = bundle?.localizedString(forKey: key, value: Self.missing, table: nil), value != Self.missing {
            return value
        }
        if let value = fallback?.localizedString(forKey: key, value: Self.missing, table: nil), value != Self.missing {
            return value
        }
        return key
    }

    public func string(_ key: String, arguments: [any CVarArg]) -> String {
        let format = string(key)
        return String(format: format, locale: locale, arguments: arguments)
    }

    /// Whether the key exists in the given language (used by tests and diagnostics).
    public func hasTranslation(_ key: String, code: String) -> Bool {
        guard let bundle = Self.lprojBundle(code: code, in: resourceBundle) else { return false }
        return bundle.localizedString(forKey: key, value: Self.missing, table: nil) != Self.missing
    }

    /// All keys known to the English (source) table.
    public func allKeys() -> [String] {
        guard let path = resourceBundle.path(forResource: "en", ofType: "lproj"),
              let dict = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Localizable.strings"))
        else { return [] }
        return dict.allKeys.compactMap { $0 as? String }.sorted()
    }
}

/// Localized string for `key` in the active interface language.
public nonisolated func L(_ key: String) -> String {
    Localizer.shared.string(key)
}

/// Localized format string for `key`, filled with `arguments`.
public nonisolated func L(_ key: String, _ arguments: any CVarArg...) -> String {
    Localizer.shared.string(key, arguments: arguments)
}
