import AppKit
import KeystivoAccessibility
import KeystivoCore

/// Window/app lifecycle events, delivered on the main actor.
public enum WindowEvent {
    case appLaunched(NSRunningApplication)
    case appTerminated(pid: pid_t, bundleID: String?)
    case appActivated(NSRunningApplication)
    case windowFocused(pid: pid_t, window: AXElement)
    case windowCreated(pid: pid_t, window: AXElement)
}

/// Fan-out of workspace + Accessibility notifications. One AX observer per
/// running app, created lazily and torn down when the app quits. No polling.
public final class WindowEventHub {
    public static let shared = WindowEventHub()

    private var bridges: [pid_t: AXObserverBridge] = [:]
    private var subscribers: [UUID: @MainActor (WindowEvent) -> Void] = [:]
    private var workspaceObservers: [any NSObjectProtocol] = []
    public private(set) var isRunning = false

    public init() {}

    @discardableResult
    public func subscribe(_ handler: @escaping @MainActor (WindowEvent) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    public func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Starts observation. Safe to call repeatedly (e.g. after permission grant).
    public func start() {
        if !isRunning {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    self?.attach(app)
                    self?.emit(.appLaunched(app))
                }
            })
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                let bundleID = app.bundleIdentifier
                MainActor.assumeIsolated {
                    self?.bridges[pid] = nil
                    self?.emit(.appTerminated(pid: pid, bundleID: bundleID))
                }
            })
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    self?.emit(.appActivated(app))
                    let element = AXElement.application(pid: app.processIdentifier)
                    if let window = element.focusedWindow {
                        self?.emit(.windowFocused(pid: app.processIdentifier, window: window))
                    }
                }
            })
            isRunning = true
        }
        guard AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app)
        }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        bridges.removeAll()
        isRunning = false
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), bridges[pid] == nil, AXIsProcessTrusted() else { return }
        guard let bridge = AXObserverBridge(pid: pid, handler: { [weak self] notification, element in
            switch notification {
            case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
                self?.emit(.windowFocused(pid: pid, window: element))
            case kAXWindowCreatedNotification:
                self?.emit(.windowCreated(pid: pid, window: element))
            default:
                break
            }
        }) else { return }
        let appElement = AXElement.application(pid: pid)
        bridge.observe(kAXFocusedWindowChangedNotification, on: appElement)
        bridge.observe(kAXWindowCreatedNotification, on: appElement)
        bridges[pid] = bridge
    }

    private func emit(_ event: WindowEvent) {
        for handler in subscribers.values { handler(event) }
    }
}
