import AppKit
import Carbon.HIToolbox
import KeystivoCore
import UserNotifications

/// Quick system commands ("hızlı sistem komutları").
nonisolated public enum SystemCommand: String, CaseIterable, Codable, Sendable, Identifiable {
    case lockScreen, sleep, sleepDisplays, screenSaver, restart, shutDown, logOut
    case emptyTrash, toggleDarkMode, toggleHiddenFiles, toggleDesktopIcons, ejectAll
    case showDesktop, missionControl, appLauncher, restartFinder, restartDock, systemSettings
    case keepAwake

    public var id: String { rawValue }
    public var titleKey: String { "system.command.\(rawValue)" }

    public var symbolName: String {
        switch self {
        case .lockScreen: "lock"
        case .sleep: "moon.zzz"
        case .sleepDisplays: "display"
        case .screenSaver: "sparkles.tv"
        case .restart: "arrow.clockwise.circle"
        case .shutDown: "power"
        case .logOut: "rectangle.portrait.and.arrow.right"
        case .emptyTrash: "trash"
        case .toggleDarkMode: "circle.lefthalf.filled"
        case .toggleHiddenFiles: "eye.slash"
        case .toggleDesktopIcons: "menubar.dock.rectangle"
        case .ejectAll: "eject"
        case .showDesktop: "desktopcomputer"
        case .missionControl: "rectangle.3.group"
        case .appLauncher: "square.grid.3x3"
        case .restartFinder: "folder.badge.gearshape"
        case .restartDock: "dock.rectangle"
        case .systemSettings: "gear"
        case .keepAwake: "cup.and.saucer"
        }
    }

    /// Commands that end the session or delete data ask for confirmation first.
    public var isDestructive: Bool {
        [.restart, .shutDown, .logOut, .emptyTrash].contains(self)
    }
}

public enum SystemCommandRunner {
    public static func run(_ command: SystemCommand) async throws {
        switch command {
        case .lockScreen:
            lockScreen()
        case .sleep:
            try await shell("/usr/bin/pmset", ["sleepnow"])
        case .sleepDisplays:
            try await shell("/usr/bin/pmset", ["displaysleepnow"])
        case .screenSaver:
            open(path: "/System/Library/CoreServices/ScreenSaverEngine.app")
        case .restart:
            try await appleScript("tell application \"System Events\" to restart")
        case .shutDown:
            try await appleScript("tell application \"System Events\" to shut down")
        case .logOut:
            try await appleScript("tell application \"System Events\" to log out")
        case .emptyTrash:
            try await appleScript("tell application \"Finder\" to empty trash")
        case .toggleDarkMode:
            try await appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .toggleHiddenFiles:
            toggleFinderPreference("AppleShowAllFiles", defaultValue: false)
            await relaunch(bundleID: "com.apple.finder")
        case .toggleDesktopIcons:
            toggleFinderPreference("CreateDesktop", defaultValue: true)
            await relaunch(bundleID: "com.apple.finder")
        case .ejectAll:
            try ejectAll()
        case .showDesktop:
            showDesktop()
        case .missionControl:
            open(path: "/System/Applications/Mission Control.app")
        case .appLauncher:
            // Launchpad was replaced by the "Apps" launcher in macOS 26.
            let candidates = ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"]
            if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) { open(path: path) }
        case .restartFinder:
            await relaunch(bundleID: "com.apple.finder")
        case .restartDock:
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").forEach { $0.forceTerminate() }
        case .systemSettings:
            open(path: "/System/Applications/System Settings.app")
        case .keepAwake:
            KeepAwakeController.shared.toggle()
        }
    }

    // MARK: Implementations

    private typealias LockFn = @convention(c) () -> Void

    static func lockScreen() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            unsafeBitCast(symbol, to: LockFn.self)()
            return
        }
        // Fallback: the standard ⌃⌘Q shortcut.
        SyntheticInput.pressKey(UInt16(kVK_ANSI_Q), modifiers: [.control, .command])
    }

    private typealias DockNotificationFn = @convention(c) (CFString, Int32) -> Void

    static func showDesktop() {
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") {
            unsafeBitCast(symbol, to: DockNotificationFn.self)("com.apple.showdesktop.awake" as CFString, 0)
        } else {
            SyntheticInput.pressKey(UInt16(kVK_F11))
        }
    }

    static func open(path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    static func toggleFinderPreference(_ key: String, defaultValue: Bool) {
        let domain = "com.apple.finder" as CFString
        let current = (CFPreferencesCopyAppValue(key as CFString, domain) as? Bool) ?? defaultValue
        CFPreferencesSetAppValue(key as CFString, (!current) as CFBoolean, domain)
        CFPreferencesAppSynchronize(domain)
    }

    static func relaunch(bundleID: String) async {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        for _ in 0..<20 where !apps.allSatisfy(\.isTerminated) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func ejectAll() throws {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var failures: [String] = []
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsEjectable == true || (values.volumeIsRemovable == true && values.volumeIsInternal == false) else { continue }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            } catch {
                failures.append(volume.lastPathComponent)
            }
        }
        if !failures.isEmpty { throw ActionError.failed(L("system.error.eject", failures.joined(separator: ", "))) }
    }

    /// Runs AppleScript in a separate `osascript` process, so a slow script never
    /// blocks the app (or the event tap that shares its main thread).
    @discardableResult
    public static func appleScript(_ source: String, timeout: Duration = .seconds(60)) async throws -> String {
        do {
            return try await run("/usr/bin/osascript", ["-e", source], timeout: timeout)
        } catch ActionError.failed(let message) where message.contains("-1743") || message.contains("Not authorized to send Apple events") {
            throw ActionError.permissionRequired(.automation)
        }
    }

    @discardableResult
    public static func shell(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(30)) async throws -> String {
        try await run(executable, arguments, timeout: timeout)
    }

    /// Runs a process with optional stdin; output is read while it runs (no pipe
    /// deadlock on large output), it's stopped after `timeout`, and cancelling the
    /// calling task (a stopped workflow) terminates it.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], input: String? = nil, timeout: Duration = .seconds(30)) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let stdin = input.map { _ in Pipe() }
        if let stdin { process.standardInput = stdin }
        let collected = OutputCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collected.append(data) }
        }
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.yield(); continuation.finish() }
        }
        try process.run()
        if let stdin, let input {
            // Off the main thread (a full pipe would block it), with the throwing
            // API (the old one raises an exception when the reader is gone).
            let handle = stdin.fileHandleForWriting
            let data = Data(input.utf8)
            Task.detached {
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            Self.stop(process)
        }
        await withTaskCancellationHandler {
            for await _ in exited {}
        } onCancel: {
            Self.stop(process)
        }
        watchdog.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        let text = String(data: collected.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Task.isCancelled { throw CancellationError() }
        if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM || process.terminationStatus == SIGKILL {
            throw ActionError.failed(L("system.error.timeout"))
        }
        guard process.terminationStatus == 0 else { throw ActionError.failed(text.isEmpty ? "exit \(process.terminationStatus)" : text) }
        return text
    }

    /// SIGTERM, then SIGKILL if it's still running two seconds later.
    nonisolated private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// Runs a macOS Shortcut by name, optionally with text input; returns its text output.
    @discardableResult
    public static func runShortcut(named name: String, input: String? = nil) async throws -> String {
        var arguments = ["run", name, "--output-path", "-"]
        if input != nil { arguments += ["--input-path", "-"] }
        return try await run("/usr/bin/shortcuts", arguments, input: input, timeout: .seconds(120))
    }
}

/// Thread-safe byte buffer for process output.
nonisolated private final class OutputCollector: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    func append(_ data: Data) { lock.withLock { buffer.append(data) } }
    var data: Data { lock.withLock { buffer } }
}

/// Local user notifications for workflows and timers.
public enum Notifier {
    private static var authorized: Bool?

    public static func post(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if authorized == nil {
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        guard authorized == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
