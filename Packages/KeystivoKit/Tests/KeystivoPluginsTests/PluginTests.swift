import Foundation
@testable import KeystivoPlugins
import Testing

@Suite("Plugins")
struct PluginTests {
    /// Creates a plugin folder with the given manifest and scripts.
    private func makePlugin(manifest: String, scripts: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keystivo-plugins-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("Test.keystivoplugin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        for (name, body) in scripts {
            let url = directory.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return directory
    }

    private let manifest = """
    {"id": "test.plugin", "name": "Test", "version": "1.0",
     "commands": [
       {"id": "list", "title": "List", "mode": "list", "script": "list.sh"},
       {"id": "echo", "title": "Echo", "mode": "silent", "script": "echo.sh", "acceptsQuery": true},
       {"id": "slow", "title": "Slow", "mode": "text", "script": "slow.sh", "timeout": 1}
     ],
     "localizations": {"tr": {"name": "Deneme", "commands": {"list": {"title": "Liste"}}}}}
    """

    private var scripts: [String: String] {
        [
            "list.sh": "#!/bin/sh\necho '{\"items\":[{\"title\":\"One\",\"action\":{\"type\":\"copy\",\"value\":\"1\"}}]}'\n",
            "echo.sh": "#!/bin/sh\necho \"hi $KEYSTIVO_QUERY\"\n",
            "slow.sh": "#!/bin/sh\nsleep 5\n",
        ]
    }

    @Test func loadsManifestAndLocalizations() throws {
        let plugin = try LoadedPlugin.load(from: try makePlugin(manifest: manifest, scripts: scripts))
        #expect(plugin.manifest.commands.count == 3)
        #expect(plugin.manifest.localizedName(for: "tr") == "Deneme")
        #expect(plugin.title(of: plugin.manifest.commands[0], language: "tr") == "Liste")
        #expect(plugin.title(of: plugin.manifest.commands[0], language: "de") == "List")
    }

    @Test func rejectsScriptsOutsideThePlugin() throws {
        let bad = manifest.replacingOccurrences(of: "\"list.sh\"", with: "\"../../evil.sh\"")
        #expect(throws: PluginError.self) { try LoadedPlugin.load(from: try makePlugin(manifest: bad, scripts: scripts)) }
    }

    @Test func rejectsInvalidIDs() throws {
        let bad = manifest.replacingOccurrences(of: "test.plugin", with: "bad id/../")
        #expect(throws: PluginError.self) { try LoadedPlugin.load(from: try makePlugin(manifest: bad, scripts: scripts)) }
    }

    @Test func untrustedPluginsDoNotRun() async throws {
        let directory = try makePlugin(manifest: manifest, scripts: scripts)
        let manager = PluginManager(directory: directory.deletingLastPathComponent())
        manager.reload()
        let plugin = try #require(manager.plugins.first)
        await #expect(throws: PluginError.notTrusted) {
            _ = try await manager.run(plugin.manifest.commands[0], of: plugin)
        }
    }

    @Test func runsListAndSilentCommands() async throws {
        let directory = try makePlugin(manifest: manifest, scripts: scripts)
        let manager = PluginManager(directory: directory.deletingLastPathComponent())
        manager.reload()
        let plugin = try #require(manager.plugins.first)
        manager.trust(plugin)
        guard case .items(let items) = try await manager.run(plugin.manifest.commands[0], of: plugin) else {
            Issue.record("expected items"); return
        }
        #expect(items.first?.title == "One")
        #expect(items.first?.action?.type == .copy)
        guard case .done(let message) = try await manager.run(plugin.manifest.commands[1], of: plugin, query: "Ada") else {
            Issue.record("expected done"); return
        }
        #expect(message == "hi Ada")
    }

    @Test func timeoutStopsRunawayScripts() async throws {
        let directory = try makePlugin(manifest: manifest, scripts: scripts)
        let manager = PluginManager(directory: directory.deletingLastPathComponent())
        manager.reload()
        let plugin = try #require(manager.plugins.first)
        manager.trust(plugin)
        await #expect(throws: PluginError.timedOut) {
            _ = try await manager.run(plugin.manifest.commands[2], of: plugin)
        }
    }

    @Test func changingFilesRevokesTrust() throws {
        let directory = try makePlugin(manifest: manifest, scripts: scripts)
        let manager = PluginManager(directory: directory.deletingLastPathComponent())
        manager.reload()
        manager.trust(try #require(manager.plugins.first))
        #expect(manager.isTrusted(try #require(manager.plugins.first)))
        try "#!/bin/sh\necho changed\n".write(to: directory.appendingPathComponent("echo.sh"), atomically: true, encoding: .utf8)
        manager.reload()
        #expect(!manager.isTrusted(try #require(manager.plugins.first)))
    }

    @Test func bundledExampleIsValid() throws {
        let url = try #require(PluginManager.bundledExampleURL)
        let plugin = try LoadedPlugin.load(from: url)
        #expect(plugin.manifest.id == "com.keystivo.examples")
        #expect(plugin.manifest.commands.count == 3)
    }
}
