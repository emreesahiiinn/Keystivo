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
    /// The card under the pointer (tracked from the pointer position, not SwiftUI hover).
    var hoveredWindowID: CGWindowID?
    /// Card frames in the panel's top-left coordinate space.
    @ObservationIgnored var cardFrames: [CGWindowID: CGRect] = [:]
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
    /// The app icon the preview belongs to (or is about to show for).
    private var currentItemTitle: String?
    /// The hovered Dock icon, in Cocoa (bottom-left) coordinates.
    private var iconFrame: CGRect?
    /// Checks the pointer while hovering the Dock or showing a preview (10 Hz).
    private var pointerTimer: Timer?
    private var pointerLeftAt: Date?
    /// After a click or a Dock menu, the preview stays away for this icon
    /// until the pointer moves to another icon or leaves the Dock.
    private var suppressedTitle: String?
    private var isDockMenuOpen = false
    /// Pending preview (hover intent delay); replaced on every hover change.
    private var showTask: Task<Void, Never>?
    private var hoverGeneration = 0
    private var enabled = false
    private var dockLaunchObserver: (any NSObjectProtocol)?
    /// Clicks on the Dock (or anywhere outside the preview) arrive here.
    private var mouseDownMonitor: Any?

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
        bridge = AXObserverBridge(pid: dock.processIdentifier) { [weak self] notification, _ in
            switch notification {
            case kAXMenuOpenedNotification: self?.dockMenuChanged(open: true)
            case kAXMenuClosedNotification: self?.dockMenuChanged(open: false)
            default: self?.selectionChanged()
            }
        }
        bridge?.observe(kAXSelectedChildrenChangedNotification, on: list)
        // Right-click / press-and-hold menus of Dock icons.
        bridge?.observe(kAXMenuOpenedNotification, on: dockElement)
        bridge?.observe(kAXMenuClosedNotification, on: dockElement)
        // Every click outside our own windows (the Dock included) is reported
        // here, however short; polling the buttons would miss quick clicks.
        if mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDownOutsidePreview() }
            }
        }
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
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
        hide()
    }

    // MARK: Hover handling

    #if DEBUG
    private var selectionEvents = 0
    private var debugState: String {
        "events=\(selectionEvents) current=\(currentItemTitle ?? "-") suppressed=\(suppressedTitle ?? "-") pending=\(showTask != nil) menu=\(isDockMenuOpen)"
    }
    #endif

    private func selectionChanged() {
        guard let list = dockList else { return }
        let selected = list.elements(kAXSelectedChildrenAttribute).first
        #if DEBUG
        selectionEvents += 1
        #endif
        hoverGeneration += 1
        showTask?.cancel()
        guard let item = selected, item.subrole == "AXApplicationDockItem" else {
            // Left the icons (or an auto-hiding Dock slid away). A visible preview
            // stays while the pointer heads to it; see checkPointer().
            suppressedTitle = nil
            if panel?.isVisible != true { currentItemTitle = nil }
            return
        }
        let title = item.title ?? ""
        if title != suppressedTitle { suppressedTitle = nil }
        guard suppressedTitle == nil, !isDockMenuOpen else { return }
        guard title != currentItemTitle || panel?.isVisible != true else { return }
        let appURL: URL? = item.attribute(kAXURLAttribute)
        let running = NSWorkspace.shared.runningApplications.first { app in
            (appURL != nil && app.bundleURL?.standardizedFileURL == appURL?.standardizedFileURL) || app.localizedName == title
        }
        guard let running, let frame = item.frame else {
            // Not running: nothing to preview. Close a preview of the previous icon.
            if panel?.isVisible == true { hide() }
            return
        }
        currentItemTitle = title
        startPointerTracking()
        let generation = hoverGeneration
        // Moving between icons with a preview open switches instantly; a fresh
        // hover waits a moment so sweeping across the Dock doesn't flash previews.
        let delay = panel?.isVisible == true ? 0 : runtime.config.dock.previewDelay
        showTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            guard !Task.isCancelled, let self, generation == self.hoverGeneration else { return }
            await self.show(app: running, itemFrame: frame, generation: generation)
        }
    }

    private func dockMenuChanged(open: Bool) {
        isDockMenuOpen = open
        guard open else { return }
        suppressCurrentIcon()
    }

    #if DEBUG
    /// End-to-end check with real input: hover a Dock icon, then right-click it.
    func runDockMenuSelfTest() async -> [String] {
        guard let list = dockList else { return ["dock list not attached"] }
        var target: (title: String, item: AXElement)?
        for item in list.children() where item.subrole == "AXApplicationDockItem" {
            guard let title = item.title,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == title }),
                  app.processIdentifier != getpid() else { continue }
            if await !WindowCatalog.shared.windows(pid: app.processIdentifier).isEmpty {
                target = (title, item)
                break
            }
        }
        guard let target, let firstFrame = target.item.frame else { return ["no Dock app with windows"] }
        let original = CGEvent(source: nil)?.location ?? .zero
        func post(_ type: CGEventType, _ button: CGMouseButton = .left, at point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        }
        var log: [String] = []
        // Start away from the Dock so an auto-hiding Dock retracts, then let it
        // slide in from the bottom edge and aim at the icon, like a real pointer.
        let screenBottom = (NSScreen.screens.first?.frame.height ?? 900) - 1
        post(.mouseMoved, at: CGPoint(x: firstFrame.midX, y: screenBottom / 2))
        try? await Task.sleep(for: .milliseconds(1500))
        post(.mouseMoved, at: CGPoint(x: firstFrame.midX, y: screenBottom - 2))
        post(.mouseMoved, at: CGPoint(x: firstFrame.midX, y: screenBottom))
        try? await Task.sleep(for: .milliseconds(1200))
        guard let frame = target.item.frame else { return ["icon frame unavailable"] }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        log.append("icon frame \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) (hidden frame y \(Int(firstFrame.minY)))")
        post(.mouseMoved, at: CGPoint(x: center.x, y: center.y - 1))
        post(.mouseMoved, at: center)
        try? await Task.sleep(for: .milliseconds(1300))
        log.append("hover \(target.title): preview visible = \(panel?.isVisible == true) [\(debugState)]")
        post(.rightMouseDown, .right, at: center)
        try? await Task.sleep(for: .milliseconds(60))
        post(.rightMouseUp, .right, at: center)
        try? await Task.sleep(for: .milliseconds(900))
        let menu = Self.openDockMenu()
        log.append("after right-click: preview visible = \(panel?.isVisible == true), dock menu open = \(menu != nil), menu notification = \(isDockMenuOpen)")
        // Close the Dock menu without sending keys to whatever app is in front.
        if let menu {
            if !menu.perform(kAXCancelAction) {
                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
            }
        }
        try? await Task.sleep(for: .milliseconds(400))
        log.append("menu closed = \(Self.openDockMenu() == nil)")
        try? await Task.sleep(for: .milliseconds(1200))
        log.append("pointer still on icon after menu: preview visible = \(panel?.isVisible == true) (expected false) [\(debugState)]")
        // Moving to another icon brings previews back.
        if let other = list.children().first(where: { $0.subrole == "AXApplicationDockItem" && $0.title != target.title && ($0.title.map { title in NSWorkspace.shared.runningApplications.contains { $0.localizedName == title } } ?? false) }),
           let otherFrame = other.frame {
            post(.mouseMoved, at: CGPoint(x: otherFrame.midX, y: otherFrame.midY))
            try? await Task.sleep(for: .milliseconds(1300))
            log.append("moved to \(other.title ?? "?"): preview visible = \(panel?.isVisible == true) (\(model.appName))")
        }
        post(.mouseMoved, at: original)
        return log
    }

    private static func openDockMenu() -> AXElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXElement.application(pid: dock.processIdentifier)
        func find(_ element: AXElement, depth: Int) -> AXElement? {
            if element.role == kAXMenuRole { return element }
            guard depth < 4 else { return nil }
            for child in element.children(limit: 200) { if let menu = find(child, depth: depth + 1) { return menu } }
            return nil
        }
        return find(app, depth: 0)
    }
    #endif

    /// A click anywhere but the preview: on a Dock icon it launches, drags or
    /// opens the Dock's menu; the preview gets out of the way either way.
    private func mouseDownOutsidePreview() {
        guard currentItemTitle != nil || showTask != nil || panel?.isVisible == true else { return }
        if dockList?.elements(kAXSelectedChildrenAttribute).isEmpty == false {
            suppressCurrentIcon()
        } else {
            hoverGeneration += 1
            hide()
        }
    }

    /// Hides the preview and keeps it away for the hovered icon.
    private func suppressCurrentIcon() {
        hoverGeneration += 1
        showTask?.cancel()
        if let title = currentItemTitle ?? dockList?.elements(kAXSelectedChildrenAttribute).first?.title { suppressedTitle = title }
        hide()
    }

    private func show(app: NSRunningApplication, itemFrame: CGRect, generation: Int) async {
        var windows = await WindowCatalog.shared.windows(pid: app.processIdentifier)
        windows.sort { FocusHistory.shared.rank(of: $0.id) < FocusHistory.shared.rank(of: $1.id) }
        // The hover may have moved on, or the user clicked, while windows loaded.
        guard generation == hoverGeneration, suppressedTitle == nil, !isDockMenuOpen, NSEvent.pressedMouseButtons == 0 else { return }
        guard !windows.isEmpty, currentItemTitle != nil else {
            if windows.isEmpty { hide() }
            return
        }
        model.appName = app.localizedName ?? ""
        model.bundleID = app.bundleIdentifier
        model.cardFrames = [:]
        model.hoveredWindowID = nil
        model.windows = windows
        model.thumbnailWidth = runtime.config.dock.previewWidth
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: min(CGFloat(windows.count) * (model.thumbnailWidth + 12) + 24, 1400), height: model.thumbnailWidth * 0.62 + 84)
        panel.setContentSize(size)
        position(panel, near: itemFrame, size: size, appName: model.appName)
        if panel.isVisible { panel.orderFrontRegardless() } else { panel.presentAnimated(makeKey: false, rise: 8) }
        if ThumbnailService.shared.isAvailable {
            await ThumbnailService.shared.load(windows.map(\.id), width: model.thumbnailWidth)
        }
    }

    private func position(_ panel: FloatingPanel, near itemFrame: CGRect, size: CGSize, appName: String) {
        let cocoa = ScreenGeometry.toCocoa(itemFrame)
        iconFrame = cocoa
        let screen = NSScreen.screen(containing: CGPoint(x: cocoa.midX, y: cocoa.midY)) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        // Leave room for the Dock's own name tooltip next to the icon.
        let tooltipWidth = (appName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width + 36
        var origin: CGPoint
        switch orientation {
        case "left": origin = CGPoint(x: cocoa.maxX + tooltipWidth + 10, y: cocoa.midY - size.height / 2)
        case "right": origin = CGPoint(x: cocoa.minX - size.width - tooltipWidth - 10, y: cocoa.midY - size.height / 2)
        default: origin = CGPoint(x: cocoa.midX - size.width / 2, y: cocoa.maxY + 44)
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
        }), size: CGSize(width: 300, height: 200))
        return panel
    }

    // MARK: Pointer tracking

    /// SwiftUI hover isn't reliable in a panel of an inactive app, and an
    /// auto-hiding Dock clears its selection as soon as the pointer leaves it,
    /// so the pointer position decides when the preview goes away.
    private func startPointerTracking() {
        pointerLeftAt = nil
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        pointerLeftAt = nil
    }

    private func checkPointer() {
        let pointer = NSEvent.mouseLocation
        let visible = panel?.isVisible == true
        let overPanel = visible && panel!.frame.insetBy(dx: -6, dy: -6).contains(pointer)
        if let panel, visible {
            let local = CGPoint(x: pointer.x - panel.frame.minX, y: panel.frame.maxY - pointer.y)
            let hovered = overPanel ? model.cardFrames.first { $0.value.contains(local) }?.key : nil
            if model.hoveredWindowID != hovered { model.hoveredWindowID = hovered }
        }
        // A click or drag on the Dock (launching, reordering, opening its menu)
        // dismisses the preview, like the Dock's own tooltip.
        if NSEvent.pressedMouseButtons != 0, !overPanel, currentItemTitle != nil {
            suppressCurrentIcon()
            return
        }
        guard visible, let panel, let icon = iconFrame else {
            // Nothing shown yet: keep watching only while a preview is pending.
            if currentItemTitle == nil { stopPointerTracking() }
            return
        }
        model.isHovering = overPanel
        if overPanel || icon.insetBy(dx: -4, dy: -4).contains(pointer) || Self.corridor(from: icon, to: panel.frame).contains(pointer) {
            pointerLeftAt = nil
            return
        }
        // Over another Dock icon, selectionChanged() switches the preview; elsewhere it closes.
        let leftAt = pointerLeftAt ?? .now
        pointerLeftAt = leftAt
        if Date.now.timeIntervalSince(leftAt) > 0.25 { hide() }
    }

    /// The gap between the icon and the preview, so crossing it doesn't close the preview.
    static func corridor(from icon: CGRect, to panel: CGRect) -> CGRect {
        let span = icon.insetBy(dx: -40, dy: -40)
        if panel.minY >= icon.maxY { // Dock at the bottom
            return CGRect(x: span.minX, y: icon.maxY, width: span.width, height: panel.minY - icon.maxY + 6)
        }
        if panel.minX >= icon.maxX { // Dock on the left
            return CGRect(x: icon.maxX, y: span.minY, width: panel.minX - icon.maxX + 6, height: span.height)
        }
        // Dock on the right
        return CGRect(x: panel.maxX - 6, y: span.minY, width: icon.minX - panel.maxX + 6, height: span.height)
    }

    func hide() {
        showTask?.cancel()
        showTask = nil
        panel?.orderOut(nil)
        currentItemTitle = nil
        iconFrame = nil
        model.isHovering = false
        stopPointerTracking()
    }
}

struct DockPreviewView: View {
    let model: DockPreviewModel
    let onSelect: (WindowInfo) -> Void
    let onClose: (WindowInfo) -> Void

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
                        DockPreviewCard(window: window, width: model.thumbnailWidth, isHovered: model.hoveredWindowID == window.id,
                                        onSelect: { onSelect(window) }, onClose: { onClose(window) })
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                model.cardFrames[window.id] = frame
                            }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .keystivoPanelBackground(cornerRadius: 16)
    }
}

private struct DockPreviewCard: View {
    let window: WindowInfo
    let width: CGFloat
    let isHovered: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    private var hovering: Bool { isHovered }

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
        .animation(.snappy(duration: 0.15), value: isHovered)
        .onTapGesture(perform: onSelect)
    }
}
