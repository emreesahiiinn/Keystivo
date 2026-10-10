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
final class DockPreviewModel {
    var appName = ""
    var bundleID: String?
    var windows: [WindowInfo] = []
    var thumbnailWidth: CGFloat = 220
    var isHovering = false
}

/// Window previews when hovering Dock icons ("Dock üzerinde pencere önizlemeleri").
///
/// Instead of replacing the Dock, Keystivo observes the Dock's accessibility
/// tree: hovering an icon changes the Dock list's selected child, which we
/// receive as an AX notification (no polling).
final class DockPreviewController {
    let model = DockPreviewModel()
    private unowned let runtime: KeystivoRuntime
    private var bridge: AXObserverBridge?
    private var dockList: AXElement?
    private var panel: FloatingPanel?
    private var hideTask: Task<Void, Never>?
    private var currentItemTitle: String?
    private var enabled = false
    private var dockLaunchObserver: (any NSObjectProtocol)?

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled { attach() } else { detach() }
    }

    private func attach() {
        guard enabled, AXIsProcessTrusted(), bridge == nil,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let dockElement = AXElement.application(pid: dock.processIdentifier)
        guard let list = dockElement.children().first(where: { $0.role == kAXListRole }) else { return }
        bridge = AXObserverBridge(pid: dock.processIdentifier) { [weak self] _, _ in
            self?.selectionChanged()
        }
        bridge?.observe(kAXSelectedChildrenChangedNotification, on: list)
        dockList = list
        // The Dock restarts occasionally (e.g. `killall Dock`); re-attach then.
        if dockLaunchObserver == nil {
            dockLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.dock" else { return }
                MainActor.assumeIsolated {
                    self?.bridge = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.attach() }
                }
            }
        }
    }

    private func detach() {
        bridge = nil
        dockList = nil
        hide()
    }

    // MARK: Hover handling

    private func selectionChanged() {
        guard let list = dockList else { return }
        let selected = list.elements(kAXSelectedChildrenAttribute).first
        guard let item = selected, item.subrole == "AXApplicationDockItem" else {
            currentItemTitle = nil
            scheduleHide()
            return
        }
        let title = item.title ?? ""
        guard title != currentItemTitle || panel?.isVisible != true else { return }
        currentItemTitle = title
        let appURL: URL? = item.attribute(kAXURLAttribute)
        let running = NSWorkspace.shared.runningApplications.first { app in
            (appURL != nil && app.bundleURL?.standardizedFileURL == appURL?.standardizedFileURL) || app.localizedName == title
        }
        guard let running, let frame = item.frame else {
            scheduleHide()
            return
        }
        Task { await show(app: running, itemFrame: frame) }
    }

    private func show(app: NSRunningApplication, itemFrame: CGRect) async {
        var windows = await WindowCatalog.shared.windows(pid: app.processIdentifier)
        windows.sort { FocusHistory.shared.rank(of: $0.id) < FocusHistory.shared.rank(of: $1.id) }
        guard !windows.isEmpty, currentItemTitle != nil else {
            scheduleHide()
            return
        }
        hideTask?.cancel()
        model.appName = app.localizedName ?? ""
        model.bundleID = app.bundleIdentifier
        model.windows = windows
        model.thumbnailWidth = runtime.config.dock.previewWidth
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: min(CGFloat(windows.count) * (model.thumbnailWidth + 12) + 24, 1400), height: model.thumbnailWidth * 0.62 + 84)
        panel.setContentSize(size)
        position(panel, near: itemFrame, size: size)
        if panel.isVisible { panel.orderFrontRegardless() } else { panel.presentAnimated(makeKey: false, rise: 8) }
        if ThumbnailService.shared.isAvailable {
            await ThumbnailService.shared.load(windows.map(\.id), width: model.thumbnailWidth)
        }
    }

    private func position(_ panel: FloatingPanel, near itemFrame: CGRect, size: CGSize) {
        let cocoa = ScreenGeometry.toCocoa(itemFrame)
        let screen = NSScreen.screen(containing: CGPoint(x: cocoa.midX, y: cocoa.midY)) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        var origin: CGPoint
        switch orientation {
        case "left": origin = CGPoint(x: cocoa.maxX + 8, y: cocoa.midY - size.height / 2)
        case "right": origin = CGPoint(x: cocoa.minX - size.width - 8, y: cocoa.midY - size.height / 2)
        default: origin = CGPoint(x: cocoa.midX - size.width / 2, y: cocoa.maxY + 8)
        }
        origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - size.width - 6)
        origin.y = min(max(origin.y, visible.minY + 6), visible.maxY - size.height - 6)
        panel.setFrameOrigin(origin)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .popUpMenu)
        panel.acceptsKey = false
        panel.host(DockPreviewView(model: model, onSelect: { [weak self] window in
            self?.hide()
            window.focus()
        }, onClose: { [weak self] window in
            window.element?.close()
            self?.model.windows.removeAll { $0 == window }
            if self?.model.windows.isEmpty == true { self?.hide() }
        }, onHover: { [weak self] hovering in
            self?.model.isHovering = hovering
            if hovering { self?.hideTask?.cancel() } else { self?.scheduleHide() }
        }), size: CGSize(width: 300, height: 200))
        return panel
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, !model.isHovering else { return }
            if currentItemTitle != nil, !dockSelectionIsEmpty { return }
            hide()
        }
    }

    private var dockSelectionIsEmpty: Bool {
        dockList?.elements(kAXSelectedChildrenAttribute).isEmpty ?? true
    }

    func hide() {
        panel?.orderOut(nil)
        currentItemTitle = nil
    }
}

struct DockPreviewView: View {
    let model: DockPreviewModel
    let onSelect: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AppIconView(bundleID: model.bundleID, size: 16)
                Text(model.appName).font(.caption.weight(.semibold))
                Spacer()
                Text(L("dock.windowCount", model.windows.count)).font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(model.windows) { window in
                        DockPreviewCard(window: window, width: model.thumbnailWidth, onSelect: { onSelect(window) }, onClose: { onClose(window) })
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .keystivoPanelBackground(cornerRadius: 16)
        .onHover(perform: onHover)
    }
}

private struct DockPreviewCard: View {
    let window: WindowInfo
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image = ThumbnailService.shared.images[window.id] {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
                            .overlay(AppIconView(bundleID: window.bundleID, size: 40).opacity(0.6))
                    }
                }
                .frame(width: width, height: width * 0.62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if hovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help(L("launcher.action.closeWindow"))
                }
            }
            Text(window.displayTitle)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: width)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}
