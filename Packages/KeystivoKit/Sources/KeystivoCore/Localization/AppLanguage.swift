import Foundation

/// A user-selectable interface language.
///
/// `code` matches the `.lproj` folder produced from the string catalog.
nonisolated public struct AppLanguage: Identifiable, Hashable, Sendable, Codable {
    public let code: String
    public let nativeName: String

    public var id: String { code }

    public init(code: String, nativeName: String) {
        self.code = code
        self.nativeName = nativeName
    }

    /// Sentinel meaning "follow the macOS language preferences".
    public static let systemCode = "system"

    /// Languages shipped with the app, in the order they appear in Settings.
    public static let supported: [AppLanguage] = [
        AppLanguage(code: "en", nativeName: "English"),
        AppLanguage(code: "tr", nativeName: "Türkçe"),
        AppLanguage(code: "de", nativeName: "Deutsch"),
        AppLanguage(code: "fr", nativeName: "Français"),
        AppLanguage(code: "es", nativeName: "Español"),
        AppLanguage(code: "it", nativeName: "Italiano"),
        AppLanguage(code: "pt-BR", nativeName: "Português (Brasil)"),
        AppLanguage(code: "ru", nativeName: "Русский"),
        AppLanguage(code: "zh-Hans", nativeName: "简体中文"),
        AppLanguage(code: "zh-Hant", nativeName: "繁體中文"),
        AppLanguage(code: "ja", nativeName: "日本語"),
        AppLanguage(code: "ko", nativeName: "한국어"),
    ]

    public static var supportedCodes: [String] { supported.map(\.code) }

    /// Picks the best shipped language for the given preference list (defaults to the system list).
    public static func resolve(preferences: [String] = Locale.preferredLanguages) -> String {
        Bundle.preferredLocalizations(from: supportedCodes, forPreferences: preferences).first ?? "en"
    }
}
