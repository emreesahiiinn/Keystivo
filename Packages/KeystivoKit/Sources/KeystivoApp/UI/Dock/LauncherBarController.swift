import AppKit
import KeystivoAccessibility
import KeystivoAudio
import KeystivoAutomation
import KeystivoClipboard
import KeystivoCore
import KeystivoFiles
import KeystivoInput
import KeystivoLinks
import KeystivoNavigation
import KeystivoPlugins
import KeystivoSearch
import KeystivoSystem
import KeystivoTools
import KeystivoWindows
import Observation
import SwiftUI

@Observable
final class LauncherBarModel {
    var settings = LauncherBarSettings()
    var runningBundleIDs: [String] = []
    var activeBundleID: String?
    var isRevealed = true

    var items: [String] {
        var result = settings.pinnedApps
        if settings.showsRunningApps {
            for id in runningBundleIDs where !result.contains(id) { result.append(id) }
        }
        return result
    }

    var isVertical: Bool { settings.edge == .left || settings.edge == .right }
}

/// An alternative, Dock-like launcher bar ("alternatif launcher bar").
final class LauncherBarController {
    let model = LauncherBarModel()
    private unowned let runtime: KeystivoRuntime
    private var panel: FloatingPanel?
    private var observers: [any NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var hideTask: Task<Void, Never>?

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    func apply(_ settings: LauncherBarSettings) {
        model.settings = settings
        if settings.isEnabled { start() } else { stop() }
    }

    private func start() {
        refreshRunning()
        if observers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshRunning() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            })
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.isRevealed = !model.settings.autoHides
        layout()
        panel.orderFrontRegardless()
        installMouseMonitor()
    }

    private func stop() {
        panel?.orderOut(nil)
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func refreshRunning() {
        model.runningBundleIDs = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap(\.bundleIdentifier)
        model.activeBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        layout()
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .floating)
        panel.acceptsKey = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.host(LauncherBarView(model: model, controller: self), size: CGSize(width: 60, height: 300))
        return panel
    }

    /// Size and place the bar along the configured edge of the main screen.
    func layout() {
        guard let panel, let screen = NSScreen.main else { return }
        let count = CGFloat(max(model.items.count, 1))
        let icon = model.settings.iconSize
        let thickness = icon + 20
        let length = min(count * (icon + 10) + 24, (model.isVertical ? screen.visibleFrame.height : screen.visibleFrame.width) - 40)
        let size = model.isVertical ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
        panel.setContentSize(size)
        let frame = screen.visibleFrame
        let hiddenOffset: CGFloat = model.isRevealed ? 6 : -thickness + 3
        let origin: CGPoint = switch model.settings.edge {
        case .left: CGPoint(x: frame.minX + hiddenOffset, y: frame.midY - size.height / 2)
        case .right: CGPoint(x: frame.maxX - size.width - hiddenOffset, y: frame.midY - size.height / 2)
        case .bottom: CGPoint(x: frame.midX - size.width / 2, y: frame.minY + hiddenOffset)
        case .top: CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - hiddenOffset)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrameOrigin(origin)
        }
    }

    /// Auto-hide: reveal when the pointer touches the edge, hide when it leaves.
    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
    }

    private func mouseMoved() {
        guard model.settings.autoHides, let screen = NSScreen.main, let panel else { return }
        let point = NSEvent.mouseLocation
        let frame = screen.frame
        let atEdge: Bool = switch model.settings.edge {
        case .left: point.x <= frame.minX + 2
        case .right: point.x >= frame.maxX - 2
        case .bottom: point.y <= frame.minY + 2
        case .top: point.y >= frame.maxY - 2
        }
        let insidePanel = panel.frame.insetBy(dx: -12, dy: -12).contains(point)
        if atEdge, !model.isRevealed {
            hideTask?.cancel()
            model.isRevealed = true
            layout()
        } else if !insidePanel, model.isRevealed {
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                model.isRevealed = false
                layout()
            }
        } else if insidePanel {
            hideTask?.cancel()
        }
    }

    // MARK: Item actions

    func open(_ bundleID: String) {
        Task { try? await AppControl.toggle(bundleID: bundleID) }
    }

    func togglePin(_ bundleID: String) {
        var settings = runtime.config.dock.launcherBar
        if let index = settings.pinnedApps.firstIndex(of: bundleID) {
            settings.pinnedApps.remove(at: index)
        } else {
            settings.pinnedApps.append(bundleID)
        }
        runtime.config.dock.launcherBar = settings
    }

    func windows(of bundleID: String) async -> [WindowInfo] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        return await WindowCatalog.shared.windows(pid: app.processIdentifier)
    }
}

struct LauncherBarView: View {
    let model: LauncherBarModel
    let controller: LauncherBarController

    var body: some View {
        let layout = model.isVertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            ForEach(model.items, id: \.self) { bundleID in
                LauncherBarItem(bundleID: bundleID, model: model, controller: controller)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keystivoPanelBackground(cornerRadius: 20)
    }
}

private struct LauncherBarItem: View {
    let bundleID: String
    let model: LauncherBarModel
    let controller: LauncherBarController
    @State private var hovering = false
    @State private var windows: [WindowInfo] = []

    var body: some View {
        let running = model.runningBundleIDs.contains(bundleID)
        ZStack(alignment: model.isVertical ? .leading : .bottom) {
            AppIconView(bundleID: bundleID, size: model.settings.iconSize)
                .scaleEffect(hovering ? 1.12 : 1)
                .animation(.snappy(duration: 0.15), value: hovering)
            if running {
                Circle()
                    .fill(model.activeBundleID == bundleID ? Color.accentColor : Color.primary.opacity(0.6))
                    .frame(width: 4, height: 4)
                    .offset(x: model.isVertical ? -7 : 0, y: model.isVertical ? 0 : 7)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.open(bundleID) }
        .help(AppDisplayName.name(forBundleID: bundleID) ?? bundleID)
        .contextMenu {
            ForEach(windows) { window in
                Button(window.displayTitle) { window.focus() }
            }
            if !windows.isEmpty { Divider() }
            Button(L(model.settings.pinnedApps.contains(bundleID) ? "launcherBar.unpin" : "launcherBar.pin")) { controller.togglePin(bundleID) }
            if running {
                Button(L("launcher.action.hideApp")) { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.hide() } }
                Button(L("launcher.action.quitApp")) { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() } }
            }
        }
        .task(id: hovering) {
            if hovering { windows = await controller.windows(of: bundleID) }
        }
    }
}
