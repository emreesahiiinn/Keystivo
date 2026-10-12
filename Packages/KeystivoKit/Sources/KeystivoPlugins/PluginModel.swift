import CryptoKit
import Foundation
import KeystivoCore

/// `manifest.json` of a plugin bundle (`<name>.keystivoplugin/`).
nonisolated public struct PluginManifest: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var author: String?
    public var description: String?
    public var icon: String?
    public var commands: [PluginCommand]
    /// Per-language overrides: `{"tr": {"name": "…", "commands": {"id": {"title": "…"}}}}`.
    public var localizations: [String: PluginLocalization]?
    /// Minimum manifest schema this plugin targets.
    public var schemaVersion: Int?

    public func localizedName(for language: String) -> String {
        localizations?[language]?.name ?? name
    }
}

nonisolated public struct PluginLocalization: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?
    public var commands: [String: PluginCommandLocalization]?
}

nonisolated public struct PluginCommandLocalization: Codable, Hashable, Sendable {
    public var title: String?
    public var subtitle: String?
}

nonisolated public struct PluginCommand: Codable, Hashable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable {
        /// Runs and shows a short confirmation.
        case silent
        /// Shows stdout as text.
        case text
        /// stdout is JSON (`PluginListOutput`) rendered as launcher results.
        case list
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var keywords: [String]?
    public var mode: Mode
    /// Path relative to the plugin directory.
    public var script: String
    public var arguments: [String]?
    /// Seconds before the script is terminated (default 10, max 120).
    public var timeout: Double?
    /// The launcher passes text typed after the command as `KEYSTIVO_QUERY`.
    public var acceptsQuery: Bool?
}

/// JSON emitted by `list` commands.
nonisolated public struct PluginListOutput: Codable, Sendable {
    public var items: [PluginItem]
}

nonisolated public struct PluginItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { [title, subtitle ?? "", action?.value ?? ""].joined(separator: "|") }
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var action: PluginItemAction?
}

nonisolated public struct PluginItemAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case open, copy, paste, notify, run }
    public var type: Kind
    public var value: String
}

public enum PluginOutput: Sendable {
    case done(String?)
    case text(String)
    case items([PluginItem])
}

public enum PluginError: LocalizedError, Equatable {
    case invalidManifest(String)
    case notTrusted
    case scriptMissing(String)
    case timedOut
    case failed(Int32, String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): L("plugins.error.manifest", reason)
        case .notTrusted: L("plugins.error.untrusted")
        case .scriptMissing(let path): L("plugins.error.scriptMissing", path)
        case .timedOut: L("plugins.error.timeout")
        case .failed(let code, let output): L("plugins.error.failed", Int(code), output)
        case .invalidOutput(let reason): L("plugins.error.output", reason)
        }
    }
}

/// A plugin discovered on disk.
nonisolated public struct LoadedPlugin: Identifiable, Hashable, Sendable {
    public var id: String { manifest.id }
    public let manifest: PluginManifest
    public let directory: URL
    /// Fingerprint of manifest + scripts; changes require re-approval.
    public let contentHash: String

    public static func load(from directory: URL) throws -> LoadedPlugin {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data: Data
        do { data = try Data(contentsOf: manifestURL) } catch { throw PluginError.invalidManifest(L("plugins.error.noManifest")) }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) } catch {
            throw PluginError.invalidManifest(error.localizedDescription)
        }
        guard !manifest.id.isEmpty, manifest.id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw PluginError.invalidManifest(L("plugins.error.badID"))
        }
        for command in manifest.commands {
            let scriptURL = directory.appendingPathComponent(command.script).standardizedFileURL
            // Scripts must live inside the plugin directory.
            guard scriptURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
                throw PluginError.invalidManifest(L("plugins.error.scriptOutside", command.script))
            }
        }
        let hash = fingerprint(of: directory)
        return LoadedPlugin(manifest: manifest, directory: directory, contentHash: hash)
    }

    /// Every file in the plugin folder (helpers and data included) with its
    /// relative path, so any change revokes trust.
    public static func fingerprint(of directory: URL) -> String {
        var hasher = SHA256()
        let root = directory.standardizedFileURL.path
        let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? [])
            .map { $0.standardizedFileURL }
            .sorted { $0.path < $1.path }
        for file in files {
            hasher.update(data: Data(String(file.path.dropFirst(root.count)).utf8))
            if let contents = try? Data(contentsOf: file, options: .mappedIfSafe) { hasher.update(data: contents) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func title(of command: PluginCommand, language: String) -> String {
        manifest.localizations?[language]?.commands?[command.id]?.title ?? command.title
    }

    public func subtitle(of command: PluginCommand, language: String) -> String? {
        manifest.localizations?[language]?.commands?[command.id]?.subtitle ?? command.subtitle
    }
}
