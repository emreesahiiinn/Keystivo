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
import SwiftUI

/// Shows/hides the launcher panel and routes keyboard navigation to the model.
final class LauncherController {
    let model: LauncherModel
    private unowned let runtime: KeystivoRuntime
    private var panel: FloatingPanel?
    private var keyMonitor: Any?

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
        model = LauncherModel(runtime: runtime)
        model.onDismiss = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(mode: LauncherMode) {
        if isVisible, model.mode == mode { hide() } else { show(mode: mode) }
    }

    func show(mode: LauncherMode) {
        // Text actions in apps that don't expose their selection (Electron, terminals,
        // web views): copy it while that app still has keyboard focus, then open.
        if mode == .textActions, !isVisible, !LauncherModel.hasAXSelection {
            Task {
                model.prefetchedSelection = await LauncherModel.copySelection()
                model.open(mode: mode)
                present()
            }
            return
        }
        model.open(mode: mode)
        present()
    }

    func show(pluginOutput: PluginOutput, title: String) {
        model.showPluginOutput(pluginOutput, title: title)
        present()
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.underMouse
        let wasVisible = panel.isVisible
        if runtime.config.launcher.position == .center { panel.center(on: screen) } else { panel.position(on: screen) }
        if wasVisible {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.presentAnimated(makeKey: true)
        }
        installKeyMonitor()
    }

    func hide() {
        guard let panel, panel.isVisible, keyMonitor != nil else { return }
        removeKeyMonitor()
        model.isActionPanelOpen = false
        panel.dismissAnimated()
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(size: Theme.launcherSize, level: .modalPanel)
        panel.host(LauncherView(model: model), size: Theme.launcherSize)
        panel.onResignKey = { [weak self] in
            // Clicking elsewhere dismisses the launcher, like Spotlight.
            DispatchQueue.main.async { self?.hide() }
        }
        return panel
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            switch event.type {
            case .keyDown:
                return self.handle(event) ? nil : event
            case .rightMouseDown, .leftMouseDown where event.modifierFlags.contains(.control):
                // A secondary click selects the row under the pointer before its menu opens.
                if let content = panel.contentView {
                    let location = content.convert(event.locationInWindow, from: nil)
                    let point = CGPoint(x: location.x, y: content.isFlipped ? location.y : content.bounds.height - location.y)
                    if let index = self.model.rowIndex(at: point) { self.model.selectedIndex = index }
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was handled.
    private func handle(_ event: NSEvent) -> Bool {
        // Never steal keys while an input method (Chinese, Japanese, Korean) is composing.
        if let textView = panel?.firstResponder as? NSTextView, textView.hasMarkedText() { return false }
        let modifiers = KeyModifiers(event.modifierFlags).subtracting(.function)
        let code = Self.layoutIndependentKeyCode(event, modifiers: modifiers)
        if model.isConfirmingClear {
            switch (code, modifiers) {
            case (KeyCodes.escape, []): model.cancelClearClipboard()
            case (KeyCodes.returnKey, []), (KeyCodes.keypadEnter, []): model.clearClipboard(keepPinned: true)
            case (KeyCodes.returnKey, [.command]): model.clearClipboard(keepPinned: false)
            default: break
            }
            return true
        }
        switch (code, modifiers) {
        case (KeyCodes.downArrow, []), (UInt16(45), [.control]): // ⌃N
            model.moveSelection(1); return true
        case (KeyCodes.upArrow, []), (UInt16(35), [.control]): // ⌃P
            model.moveSelection(-1); return true
        case (KeyCodes.returnKey, []), (KeyCodes.keypadEnter, []):
            model.performSelected(); return true
        case (KeyCodes.returnKey, [.command]):
            if model.isActionPanelOpen { model.performSelected() } else { model.performSelected(alternate: true) }
            return true
        case (KeyCodes.escape, []):
            model.back(); return true
        case (UInt16(40), [.command]): // ⌘K
            model.toggleActionPanel(); return true
        case (UInt16(43), [.command]): // ⌘,
            hide()
            runtime.windowsUI.showSettings()
            return true
        case (KeyCodes.delete, []) where model.query.isEmpty && model.mode != .root:
            model.open(mode: .root); return true
        case (KeyCodes.tab, []) where model.mode == .root:
            // Tab autocompletes the selected item's title.
            if let title = model.selectedItem?.title { model.query = title }
            return true
        default:
            break
        }
        // ⌘1…⌘9 run the n-th visible result.
        if modifiers == .command, let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
            let index = digit - 1
            if model.items.indices.contains(index) {
                model.selectedIndex = index
                model.performSelected()
            }
            return true
        }
        if !modifiers.isEmpty, model.performShortcut(KeyCombo(keyCode: code, modifiers: modifiers)) {
            return true
        }
        return false
    }

    /// Letter shortcuts follow the keyboard layout: ⌘K is the key labeled K on
    /// Turkish-F, AZERTY or Dvorak. Non-Latin layouts keep the physical key, as macOS does.
    static func layoutIndependentKeyCode(_ event: NSEvent, modifiers: KeyModifiers) -> UInt16 {
        guard !modifiers.intersection([.command, .control]).isEmpty,
              let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1,
              let character = characters.first, character.isASCII else { return event.keyCode }
        if let letter = KeyCodes.letterKeyCodes[character] { return letter }
        return character == "," ? 43 : event.keyCode
    }

    #if DEBUG
    /// Debug: right-clicks result row `index`, to check the context menu visually.
    func debugRightClickRow(_ index: Int) {
        guard let frame = panel?.frame, let screenHeight = NSScreen.screens.first?.frame.height else { return }
        let point = CGPoint(x: frame.minX + 160, y: screenHeight - frame.maxY + 85 + CGFloat(index) * 43)
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .right)?.post(tap: .cghidEventTap)
        }
    }
    #endif
}
