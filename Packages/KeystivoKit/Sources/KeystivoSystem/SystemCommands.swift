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
            try appleScript("tell application \"System Events\" to restart")
        case .shutDown:
            try appleScript("tell application \"System Events\" to shut down")
        case .logOut:
            try appleScript("tell application \"System Events\" to log out")
        case .emptyTrash:
            try appleScript("tell application \"Finder\" to empty trash")
        case .toggleDarkMode:
            try appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
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

    public static func appleScript(_ source: String) throws {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw ActionError.failed(L("system.error.script")) }
        script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { throw ActionError.permissionRequired(.automation) }
            throw ActionError.failed(error[NSAppleScript.errorMessage] as? String ?? L("system.error.script"))
        }
    }

    @discardableResult
    public static func shell(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(30)) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else { throw ActionError.failed(text.isEmpty ? "exit \(process.terminationStatus)" : text) }
            return text
        }.value
    }

    /// Runs a macOS Shortcut by name (e.g. one that toggles a Focus/Do Not Disturb).
    public static func runShortcut(named name: String, input: String? = nil) async throws {
        var arguments = ["run", name]
        if input != nil { arguments += ["--input-path", "-"] }
        try await shell("/usr/bin/shortcuts", arguments)
    }
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
