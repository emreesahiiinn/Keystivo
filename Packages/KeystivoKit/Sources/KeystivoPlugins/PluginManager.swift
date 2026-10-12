import AppKit
import KeystivoCore
import Observation

/// Discovers, trusts and runs script plugins ("eklenti mimarisi").
///
/// Plugins are folders in `~/Library/Application Support/Keystivo/Plugins`
/// containing a `manifest.json` and executable scripts in any language. They
/// run as separate processes, so a faulty plugin can never crash Keystivo.
/// A plugin must be explicitly trusted, and any change to its files revokes
/// trust until the user approves it again.
@Observable
public final class PluginManager {
    public static let shared = PluginManager()

    public private(set) var plugins: [LoadedPlugin] = []
    public private(set) var loadErrors: [String: String] = [:]
    /// plugin ID → approved content hash.
    public var trusted: [String: String] = [:] {
        didSet { onChange?() }
    }
    public var disabled: Set<String> = [] {
        didSet { onChange?() }
    }
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public let directory: URL

    public init(directory: URL = AppPaths.pluginsDirectory) {
        self.directory = directory
    }

    public func reload() {
        var loaded: [LoadedPlugin] = []
        var errors: [String: String] = [:]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            do {
                let plugin = try LoadedPlugin.load(from: entry)
                if loaded.contains(where: { $0.id == plugin.id }) { continue }
                loaded.append(plugin)
            } catch {
                errors[entry.lastPathComponent] = error.localizedDescription
                DiagnosticsCenter.shared.record(.warning, module: "Plugins", L("plugins.error.load", entry.lastPathComponent), detail: error.localizedDescription)
            }
        }
        plugins = loaded.sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        loadErrors = errors
    }

    public func isTrusted(_ plugin: LoadedPlugin) -> Bool { trusted[plugin.id] == plugin.contentHash }
    public func isEnabled(_ plugin: LoadedPlugin) -> Bool { isTrusted(plugin) && !disabled.contains(plugin.id) }

    public func trust(_ plugin: LoadedPlugin) {
        trusted[plugin.id] = plugin.contentHash
        disabled.remove(plugin.id)
    }

    public func revoke(_ plugin: LoadedPlugin) { trusted[plugin.id] = nil }

    public func setEnabled(_ enabled: Bool, for plugin: LoadedPlugin) {
        if enabled { disabled.remove(plugin.id) } else { disabled.insert(plugin.id) }
    }

    public var enabledCommands: [(LoadedPlugin, PluginCommand)] {
        plugins.filter(isEnabled).flatMap { plugin in plugin.manifest.commands.map { (plugin, $0) } }
    }

    public func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: Running

    public func run(_ command: PluginCommand, of plugin: LoadedPlugin, query: String = "") async throws -> PluginOutput {
        // Re-read the files: an edit since approval revokes trust immediately, not at the next restart.
        guard isEnabled(plugin), trusted[plugin.id] == LoadedPlugin.fingerprint(of: plugin.directory) else { throw PluginError.notTrusted }
        let script = plugin.directory.appendingPathComponent(command.script)
        guard FileManager.default.fileExists(atPath: script.path) else { throw PluginError.scriptMissing(command.script) }
        let environment = [
            "KEYSTIVO_QUERY": query,
            "KEYSTIVO_LANGUAGE": Localizer.shared.languageCode,
            "KEYSTIVO_PLUGIN_DIR": plugin.directory.path,
            "KEYSTIVO_SUPPORT_DIR": AppPaths.applicationSupport.path,
            "KEYSTIVO_VERSION": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
        ]
        let timeout = min(max(command.timeout ?? 10, 1), 120)
        let output = try await ScriptRunner.run(script: script, arguments: command.arguments ?? [], environment: environment, workingDirectory: plugin.directory, timeout: timeout)
        switch command.mode {
        case .silent:
            return .done(output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        case .text:
            return .text(output)
        case .list:
            guard let data = output.data(using: .utf8) else { throw PluginError.invalidOutput("utf8") }
            do {
                return .items(try JSONDecoder().decode(PluginListOutput.self, from: data).items)
            } catch {
                throw PluginError.invalidOutput(error.localizedDescription)
            }
        }
    }

    /// Copies the bundled example plugin into the plugins folder.
    public func installExample(from source: URL) throws {
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        // Resource copies lose the executable bit.
        if let files = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil) {
            for case let file as URL in files where ["sh", "py", "rb", "js", "swift", "zsh"].contains(file.pathExtension) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        reload()
    }
}

/// Runs a script with a timeout, capturing stdout (stderr is appended on failure).
/// Output is read as it arrives, and a script that outlives its timeout is
/// stopped (SIGTERM, then SIGKILL) without waiting for children that keep its pipes open.
public enum ScriptRunner {
    public static func run(script: URL, arguments: [String], environment: [String: String], workingDirectory: URL, timeout: Double) async throws -> String {
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let out = Buffer(), err = Buffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in out.append(handle.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { handle in err.append(handle.availableData) }
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.yield(); continuation.finish() }
        }
        do {
            try process.run()
        } catch {
            throw PluginError.failed(-1, error.localizedDescription)
        }
        let timedOut = Buffer()
        let watchdog = Task.detached {
            try await Task.sleep(for: .seconds(timeout))
            timedOut.append(Data([1]))
            process.terminate()
            let pid = process.processIdentifier
            try await Task.sleep(for: .seconds(1))
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        await withTaskCancellationHandler {
            for await _ in exited {}
        } onCancel: {
            process.terminate()
        }
        watchdog.cancel()
        // Let the last chunks arrive, but never wait on pipes held open by child processes.
        try? await Task.sleep(for: .milliseconds(30))
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if Task.isCancelled || process.isRunning {
            // Cancelled (e.g. a workflow was stopped): the script was only asked to
            // quit. `terminationStatus` of a running process raises an exception.
            let pid = process.processIdentifier
            if process.isRunning {
                Task.detached {
                    try? await Task.sleep(for: .seconds(1))
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
            throw CancellationError()
        }
        if !timedOut.data.isEmpty { throw PluginError.timedOut }
        let output = String(data: out.data, encoding: .utf8) ?? ""
        let errors = String(data: err.data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw PluginError.failed(process.terminationStatus, String((errors.isEmpty ? output : errors).prefix(500)))
        }
        return output
    }

    nonisolated private final class Buffer: @unchecked Sendable {
        private var storage = Data()
        private let lock = NSLock()
        func append(_ data: Data) { lock.withLock { storage.append(data) } }
        var data: Data { lock.withLock { storage } }
    }
}


extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public extension PluginManager {
    /// The example plugin shipped inside the app bundle.
    static var bundledExampleURL: URL? {
        Bundle.module.url(forResource: "Examples", withExtension: "keystivoplugin")
    }
}
