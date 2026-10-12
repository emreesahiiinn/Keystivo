import AppKit
import KeystivoCore
import SwiftUI

// MARK: - Surface

/// The surface of Keystivo's floating panels: frosted glass that lets the
/// desktop show through, a hairline edge, and an optional hint bar.
struct PanelSurface: ViewModifier {
    var background: PanelBackground
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background { backdrop.clipShape(shape) }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.75))
            .clipShape(shape)
    }

    @ViewBuilder
    private var backdrop: some View {
        switch background {
        case .glass:
            VisualEffectBackground(material: .hudWindow)
        case .clear:
            if #available(macOS 26, *) {
                Color.black.opacity(0.12).glassEffect(.clear, in: Rectangle())
            } else {
                VisualEffectBackground(material: .hudWindow).opacity(0.7)
            }
        case .solid:
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

extension View {
    func panelSurface(_ background: PanelBackground, cornerRadius: CGFloat = 14) -> some View {
        modifier(PanelSurface(background: background, cornerRadius: cornerRadius))
    }
}

/// Closes the panel a view lives in (menu bar panels).
struct DismissPanelAction {
    var action: () -> Void = {}
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    @Entry var dismissPanel = DismissPanelAction()
}

/// Scrolls when taller than the screen; follows the background setting live.
/// Reports the content's height so the panel can fit it (outside of layout).
private struct MenuBarPanelRoot: View {
    let width: CGFloat
    let content: AnyView
    let onHeight: (CGFloat) -> Void

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .panelSurface(KeystivoRuntime.shared.config.menuBar.controlCenter.background)
    }
}

// MARK: - Panel

/// A panel that hangs below a menu bar item.
final class MenuBarPanel: FloatingPanel {
    /// Handles a key press before the content does; true = handled.
    var onKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }
}

/// A menu bar item that opens a glass panel below it: Keystivo's control
/// center and the sound mixer.
final class MenuBarPanelController: NSObject {
    private let autosaveName: String
    private let width: CGFloat
    private let content: () -> AnyView
    private let onShow: () -> Void
    private var item: NSStatusItem?
    private var panel: MenuBarPanel?
    private var clickMonitor: Any?
    /// When the panel last closed by losing focus: a click on the item that
    /// caused it must not reopen the panel right away.
    private var resignedAt = Date.distantPast
    /// Height of the content at the panel's width.
    private var contentHeight: CGFloat = 300
    /// Screen y of the panel's top edge (AppKit coordinates).
    private var anchorTop: CGFloat?
    /// Bumped on every show and close, so a late close animation can't hide a reopened panel.
    private var generation = 0
    /// The item's symbol; may change with state (e.g. volume level).
    var symbol: () -> String
    var accessibilityLabel: String

    init(autosaveName: String, width: CGFloat, accessibilityLabel: String, symbol: @escaping () -> String,
         onShow: @escaping () -> Void = {}, content: @escaping () -> AnyView) {
        self.autosaveName = autosaveName
        self.width = width
        self.accessibilityLabel = accessibilityLabel
        self.symbol = symbol
        self.onShow = onShow
        self.content = content
    }

    var isShown: Bool { panel?.isVisible == true }

    func setInstalled(_ installed: Bool) {
        if installed, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = autosaveName
            item.button?.target = self
            item.button?.action = #selector(clicked)
            item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
            self.item = item
            refreshIcon()
        } else if !installed, let item {
            close()
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func refreshIcon() {
        guard let button = item?.button else { return }
        let image = NSImage(systemSymbolName: symbol(), accessibilityDescription: accessibilityLabel)
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(accessibilityLabel)
    }

    @objc private func clicked() {
        if isShown { close(); return }
        guard Date.now.timeIntervalSince(resignedAt) > 0.25 else { return }
        show()
    }

    func toggle() {
        isShown ? close() : show()
    }

    func show() {
        onShow()
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let dismiss = DismissPanelAction { [weak self] in self?.close() }
        // The window is sized here, never by SwiftUI during layout: letting the
        // hosting view resize its own window while laying out could re-enter
        // layout until the stack ran out (a crash when a section changed size).
        let measure = NSHostingView(rootView: content().frame(width: width).environment(\.dismissPanel, dismiss).localizedRoot())
        contentHeight = measure.fittingSize.height
        let host = NSHostingView(rootView: MenuBarPanelRoot(width: width, content: content()) { [weak self] height in
            self?.contentHeightChanged(height)
        }
        .environment(\.dismissPanel, dismiss)
        .localizedRoot())
        host.sizingOptions = []
        panel.contentView = host
        position(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        item?.button?.highlight(true)
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        item?.button?.highlight(false)
        guard let panel, panel.isVisible else { return }
        generation += 1
        let closing = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Reopened meanwhile: leave the new content alone.
                guard let self, self.generation == closing else { return }
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }

    /// The content grew or shrank (e.g. a section expanded): fit it after this layout pass.
    private func contentHeightChanged(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        DispatchQueue.main.async { [weak self] in self?.fitHeight(animated: true) }
    }

    private func fitHeight(animated: Bool) {
        guard let panel, panel.isVisible, let anchorTop else { return }
        let height = max(min(contentHeight, maxHeight()), 40).rounded()
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let frame = NSRect(x: panel.frame.minX, y: anchorTop - height, width: width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func makePanel() -> MenuBarPanel {
        let panel = MenuBarPanel(size: CGSize(width: width, height: 200))
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.onResignKey = { [weak self] in
            guard let self, self.isShown else { return }
            self.resignedAt = .now
            DispatchQueue.main.async { self.close() }
        }
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        return panel
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 53, modifiers.isEmpty {
            close()
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return false
    }

    private func screen() -> NSScreen? {
        item?.button?.window?.screen ?? NSScreen.underMouse ?? NSScreen.main
    }

    private func maxHeight() -> CGFloat {
        guard let screen = screen() else { return 700 }
        return screen.visibleFrame.height - 16
    }

    private func position(_ panel: MenuBarPanel) {
        guard let screen = screen() else { return }
        let visible = screen.visibleFrame
        var anchor = CGRect(x: visible.maxX - width - 8, y: visible.maxY, width: width, height: 0)
        if let button = item?.button, let window = button.window {
            anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let top = min(anchor.minY, visible.maxY) - 5
        let x = min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        anchorTop = top
        let height = max(min(contentHeight, maxHeight()), 40).rounded()
        panel.setFrame(NSRect(x: x.rounded(), y: top - height, width: width, height: height), display: false)
    }
}
