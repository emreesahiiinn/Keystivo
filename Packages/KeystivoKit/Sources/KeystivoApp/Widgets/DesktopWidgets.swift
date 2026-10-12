import AppKit
import KeystivoCore
import SwiftUI

/// Desktop widgets: one glass panel per widget, sitting on the desktop (below
/// windows) or always on top. Drag one anywhere; its place is remembered.
final class DesktopWidgetsController: NSObject, NSWindowDelegate {
    private unowned let runtime: KeystivoRuntime
    private var panels: [UUID: WidgetPanel] = [:]

    /// Just above the desktop icons, below every app window.
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    func apply(_ settings: WidgetSettings) {
        let wanted = settings.showsDesktopWidgets ? settings.desktop : []
        let wantedIDs = Set(wanted.map(\.id))
        for (id, panel) in panels where !wantedIDs.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for instance in wanted {
            let panel = panels[instance.id] ?? makePanel(for: instance)
            panels[instance.id] = panel
            let size = instance.size.points
            var origin = instance.origin ?? autoOrigin(size: size, excluding: instance.id)
            if instance.origin == nil {
                let id = instance.id
                let placed = origin
                DispatchQueue.main.async { [weak self] in self?.runtime.updateWidget(id) { $0.origin = placed } }
            }
            origin = Self.keepOnScreen(origin, size: size)
            let frame = CGRect(origin: origin, size: size)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            panel.level = settings.alwaysOnTop ? .floating : Self.desktopLevel
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    func toggleVisibility() {
        runtime.config.widgets.showsDesktopWidgets.toggle()
    }

    private func makePanel(for instance: WidgetInstance) -> WidgetPanel {
        let panel = WidgetPanel(id: instance.id)
        panel.delegate = self
        let host = NSHostingView(rootView: DesktopWidgetHost(runtime: runtime, id: instance.id, fallback: instance).localizedRoot())
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// The first free spot in a column grid from the top-right of the main display.
    private func autoOrigin(size: CGSize, excluding id: UUID) -> CGPoint {
        let visible = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let occupied = panels.filter { $0.key != id && $0.value.isVisible }.map(\.value.frame)
        let gap: CGFloat = 16
        var x = visible.maxX - gap - size.width
        while x > visible.minX {
            var y = visible.maxY - gap - size.height
            while y > visible.minY {
                let candidate = CGRect(x: x, y: y, width: size.width, height: size.height)
                if !occupied.contains(where: { $0.insetBy(dx: -gap / 2, dy: -gap / 2).intersects(candidate) }) {
                    return candidate.origin
                }
                y -= 8
            }
            x -= 8
        }
        return CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    }

    /// Displays come and go: a widget left off-screen comes back to the nearest one.
    private static func keepOnScreen(_ origin: CGPoint, size: CGSize) -> CGPoint {
        let frame = CGRect(origin: origin, size: size)
        if NSScreen.screens.contains(where: { $0.frame.intersects(frame.insetBy(dx: size.width / 3, dy: size.height / 3)) }) { return origin }
        guard let screen = NSScreen.screens.first else { return origin }
        let visible = screen.visibleFrame
        return CGPoint(x: min(max(origin.x, visible.minX), visible.maxX - size.width), y: min(max(origin.y, visible.minY), visible.maxY - size.height))
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? WidgetPanel, panel.isVisible else { return }
        // Settle on a 4-point grid so neighbors line up.
        let origin = CGPoint(x: (panel.frame.minX / 4).rounded() * 4, y: (panel.frame.minY / 4).rounded() * 4)
        let id = panel.widgetID
        guard runtime.config.widgets.instances.first(where: { $0.id == id })?.origin != origin else { return }
        runtime.updateWidget(id) { $0.origin = origin }
    }
}

/// A widget's window: borderless, never activates Keystivo, dragged by its background.
final class WidgetPanel: NSPanel {
    let widgetID: UUID

    init(id: UUID) {
        widgetID = id
        super.init(contentRect: CGRect(x: 0, y: 0, width: 164, height: 164), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    // Notes need typing; everything else just works with clicks.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Reads its widget from the settings, so edits show up live.
private struct DesktopWidgetHost: View {
    let runtime: KeystivoRuntime
    let id: UUID
    /// Used when the widget isn't in the settings (developer previews).
    let fallback: WidgetInstance

    var body: some View {
        let instance = runtime.config.widgets.instances.first(where: { $0.id == id }) ?? fallback
        Group {
            WidgetView(runtime: runtime, instance: instance)
                .padding(14)
                .frame(width: instance.size.points.width, height: instance.size.points.height)
                .panelSurface(runtime.config.widgets.background, cornerRadius: 22)
                .contextMenu { WidgetMenu(runtime: runtime, instance: instance) }
        }
    }
}

/// Right-click menu of a widget (desktop and menu bar panel).
struct WidgetMenu: View {
    let runtime: KeystivoRuntime
    let instance: WidgetInstance

    var body: some View {
        if instance.kind.sizes.count > 1 {
            ForEach(instance.kind.sizes, id: \.self) { size in
                Button { runtime.updateWidget(instance.id) { $0.size = size; $0.origin = nil } } label: {
                    if size == instance.size { Label(L(size.titleKey), systemImage: "checkmark") } else { Text(L(size.titleKey)) }
                }
            }
            Divider()
        }
        if instance.placement == .desktop {
            Button(L("widgets.moveToPanel")) { runtime.moveWidget(instance.id, to: .panel) }
        } else {
            Button(L("widgets.moveToDesktop")) { runtime.moveWidget(instance.id, to: .desktop) }
        }
        Button(L("widgets.edit")) { runtime.windowsUI.showSettings(section: .widgets) }
        Divider()
        Button(L("widgets.remove"), role: .destructive) { runtime.removeWidget(instance.id) }
    }
}

extension KeystivoRuntime {
    func updateWidget(_ id: UUID, _ change: (inout WidgetInstance) -> Void) {
        guard let index = config.widgets.instances.firstIndex(where: { $0.id == id }) else { return }
        change(&config.widgets.instances[index])
    }

    func addWidget(_ kind: WidgetKind, placement: WidgetPlacement) {
        config.widgets.instances.append(WidgetInstance(kind: kind, placement: placement))
        if placement == .panel, !config.menuBar.controlCenter.modules.contains(.widgets) {
            config.menuBar.controlCenter.modules.insert(.widgets, at: min(1, config.menuBar.controlCenter.modules.count))
        }
        if placement == .desktop { config.widgets.showsDesktopWidgets = true }
    }

    func moveWidget(_ id: UUID, to placement: WidgetPlacement) {
        updateWidget(id) {
            $0.placement = placement
            $0.origin = nil
        }
        if placement == .panel, !config.menuBar.controlCenter.modules.contains(.widgets) {
            config.menuBar.controlCenter.modules.insert(.widgets, at: min(1, config.menuBar.controlCenter.modules.count))
        }
    }

    func removeWidget(_ id: UUID) {
        config.widgets.instances.removeAll { $0.id == id }
        WidgetNotes.shared.remove(id)
    }
}
