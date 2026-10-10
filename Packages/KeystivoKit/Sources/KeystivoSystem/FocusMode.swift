import AppKit
import KeystivoAccessibility
import KeystivoCore
import Observation

nonisolated public struct FocusSettings: Codable, Hashable, Sendable {
    public var distractingApps: [String] = [
        "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp", "com.apple.mail", "com.microsoft.Outlook", "com.apple.news",
    ]
    public var hidesDistractingApps = true
    public var quitsInsteadOfHiding = false
    /// Re-hide/quit distracting apps that are opened during a session.
    public var blocksLaunching = true
    /// Hide every app except the frontmost one when starting.
    public var hidesOtherApps = false
    /// Darken everything behind the focused window.
    public var dimsBackground = true
    public var dimOpacity = 0.45
    public var defaultMinutes = 25
    /// Optional macOS Shortcuts to run on start/end (e.g. turn on Do Not Disturb).
    public var startShortcut = ""
    public var endShortcut = ""

    public init() {}
}

/// "Odak modu ve dikkat dağıtıcıları azaltma".
@Observable
public final class FocusController {
    public static let shared = FocusController()

    public var settings = FocusSettings()
    public private(set) var isActive = false
    public private(set) var endsAt: Date?
    public private(set) var startedAt: Date?

    @ObservationIgnored public var onStart: (@MainActor () -> Void)?
    @ObservationIgnored public var onEnd: (@MainActor () -> Void)?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var launchObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var overlays: [NSWindow] = []

    public init() {}

    public func start(minutes: Int? = nil) {
        if isActive { stop(notify: false) }
        isActive = true
        startedAt = .now
        let duration = minutes ?? settings.defaultMinutes
        if duration > 0 {
            endsAt = .now.addingTimeInterval(TimeInterval(duration * 60))
            timerTask = Task {
                try? await Task.sleep(for: .seconds(duration * 60))
                guard !Task.isCancelled else { return }
                stop()
                await Notifier.post(title: L("focus.ended.title"), body: L("focus.ended.body"))
            }
        }
        if settings.hidesDistractingApps { silenceDistractingApps() }
        if settings.hidesOtherApps { NSWorkspace.shared.hideOtherApplications() }
        if settings.blocksLaunching { observeLaunches() }
        if settings.dimsBackground { showOverlays() }
        if !settings.startShortcut.isEmpty {
            let name = settings.startShortcut
            Task { try? await SystemCommandRunner.runShortcut(named: name) }
        }
        onStart?()
    }

    public func stop(notify: Bool = true) {
        guard isActive else { return }
        isActive = false
        endsAt = nil
        startedAt = nil
        timerTask?.cancel()
        timerTask = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        launchObserver = nil
        activationObserver = nil
        hideOverlays()
        if !settings.endShortcut.isEmpty {
            let name = settings.endShortcut
            Task { try? await SystemCommandRunner.runShortcut(named: name) }
        }
        if notify { onEnd?() }
    }

    public func toggle() { isActive ? stop() : start() }

    public var remaining: TimeInterval? {
        endsAt.map { max($0.timeIntervalSinceNow, 0) }
    }

    private func silenceDistractingApps() {
        for bundleID in settings.distractingApps {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                silence(app)
            }
        }
    }

    private func silence(_ app: NSRunningApplication) {
        if settings.quitsInsteadOfHiding {
            app.terminate()
        } else {
            app.hide()
        }
    }

    private func observeLaunches() {
        let center = NSWorkspace.shared.notificationCenter
        let handler: @Sendable (Notification) -> Void = { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.settings.distractingApps.contains(bundleID) else { return }
                self.silence(app)
            }
        }
        launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: handler)
        activationObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            handler(note)
            MainActor.assumeIsolated { self?.focusedWindowChanged() }
        }
    }

    // MARK: Dimming

    private func showOverlays() {
        hideOverlays()
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(settings.dimOpacity)
            window.ignoresMouseEvents = true
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.animationBehavior = .none
            overlays.append(window)
        }
        focusedWindowChanged()
    }

    private func hideOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    /// Re-orders the dimming layer directly beneath the focused window.
    public func focusedWindowChanged() {
        guard isActive, settings.dimsBackground, !overlays.isEmpty else { return }
        guard let focused = WindowCatalog.shared.focusedWindow(), let windowID = focused.windowID else {
            overlays.forEach { $0.orderFront(nil) }
            return
        }
        for overlay in overlays {
            overlay.order(.below, relativeTo: Int(windowID))
        }
    }
}
