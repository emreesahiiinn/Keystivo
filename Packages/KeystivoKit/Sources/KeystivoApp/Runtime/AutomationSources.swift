import AppKit
import KeystivoAutomation
import KeystivoClipboard
import KeystivoCore
import Network

/// System events for workflow triggers that aren't covered elsewhere: mounted
/// volumes, network changes, idle time, appearance and the clipboard. Also
/// the interactive pieces of workflows (asking for input, large text).
final class AutomationSources {
    private unowned let runtime: KeystivoRuntime
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var pathMonitor: NWPathMonitor?
    private var lastPathDescription: String?
    private var idleTimer: Timer?
    private var reportedIdleMinutes = 0

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    func start() {
        let engine = AutomationEngine.shared
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didMountNotification) { name in
            engine.handle(.volumeMounted(name))
        }
        observe(workspace, NSWorkspace.didUnmountNotification) { name in
            engine.handle(.volumeUnmounted(name))
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification")) { _ in
            engine.handle(.appearanceChanged)
        }
        ClipboardMonitor.shared.onCapture = { _ in engine.handle(.clipboardChanged) }

        // Network: interfaces or reachability changed (Wi-Fi ↔ Ethernet, VPN, offline).
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let description = "\(path.status)|\(path.availableInterfaces.map(\.name).sorted())"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    defer { self.lastPathDescription = description }
                    guard let last = self.lastPathDescription, last != description else { return }
                    engine.handle(.networkChanged)
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor

        // Idle time: checked every 20 s (cheap), reported once per whole minute.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer

        engine.onAskInput = { prompt, workflow in Self.askForInput(prompt: prompt, title: workflow) }
        engine.onShowText = { [weak self] text, workflow in
            self?.runtime.launcher.show(pluginOutput: .text(text), title: workflow)
        }
    }

    private func checkIdle() {
        let anyInput = CGEventType(rawValue: ~0)!
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let minutes = Int(seconds / 60)
        if minutes > reportedIdleMinutes {
            for minute in (reportedIdleMinutes + 1)...minutes { AutomationEngine.shared.handle(.userIdle(minutes: minute)) }
            reportedIdleMinutes = minutes
        } else if minutes == 0, reportedIdleMinutes > 0 {
            reportedIdleMinutes = 0
            AutomationEngine.shared.handle(.userReturned)
        }
    }

    /// Observes a notification; the handler gets the volume name when there is one.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (String) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            let volume = Self.volumeName(note)
            MainActor.assumeIsolated { handler(volume) }
        }
        observers.append((center, token))
    }

    nonisolated private static func volumeName(_ note: Notification) -> String {
        (note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String)
            ?? (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.lastPathComponent ?? ""
    }

    /// A small text prompt; nil when cancelled.
    static func askForInput(prompt: String, title: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = prompt
        alert.addButton(withTitle: L("common.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// `keystivo://run/<name>?key=value`, `keystivo://launcher?query=…`,
    /// `keystivo://settings/<page>`. Only workflows with a matching URL trigger run.
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "keystivo" else { return }
        let parameters = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                                    uniquingKeysWith: { _, last in last })
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host()?.lowercased() {
        case "run":
            guard let name = parts.first?.removingPercentEncoding else { return }
            AutomationEngine.shared.handleURL(name: name, parameters: parameters)
        case "launcher":
            runtime.launcher.show(mode: .root)
            if let query = parameters["query"] { runtime.launcher.model.query = query }
        case "settings":
            runtime.windowsUI.showSettings(section: parts.first.flatMap(SettingsSection.init(rawValue:)) ?? .general)
        default:
            break
        }
    }
}
