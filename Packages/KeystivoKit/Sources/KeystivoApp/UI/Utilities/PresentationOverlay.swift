import AppKit
import Carbon.HIToolbox
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
final class PresentationModel {
    struct Ripple: Identifiable {
        let id = UUID()
        let point: CGPoint
        let isRight: Bool
    }

    var keystrokes: [String] = []
    var ripples: [Ripple] = []
    var cursor: CGPoint = .zero
    var highlightsCursor = false
}

/// Presentation aids: on-screen keystrokes, click ripples and a cursor
/// spotlight (KeyCastr / Presentify style). Listens only while enabled and never
/// shows plain typing unless explicitly allowed.
final class PresentationOverlay: EventTapHandler {
    let model = PresentationModel()
    private var settings = PresentationSettings()
    private var windows: [OverlayWindow] = []
    private var clearTask: Task<Void, Never>?
    private var mouseMonitor: Any?

    init() {
        EventTapManager.shared.add(self)
    }

    func apply(_ settings: PresentationSettings) {
        self.settings = settings
        model.highlightsCursor = settings.highlightsCursor
        let active = settings.showsKeystrokes || settings.showsClicks || settings.highlightsCursor
        if active { showWindows() } else { hideWindows() }
        if settings.highlightsCursor { startCursorTracking() } else { stopCursorTracking() }
        EventTapManager.shared.refresh()
    }

    private func showWindows() {
        guard windows.isEmpty else { return }
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.level = .screenSaver
            window.contentView = NSHostingView(rootView: PresentationView(model: model, screenFrame: ScreenGeometry.frameAX(of: screen)))
            window.orderFrontRegardless()
            return window
        }
    }

    private func hideWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func startCursorTracking() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.cursor = ScreenGeometry.toAX(point: NSEvent.mouseLocation) }
        }
    }

    private func stopCursorTracking() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: Event tap (listen only — always passes events through)

    var eventTapPriority: Int { 1 }

    var eventTapTypes: Set<CGEventType> {
        var types: Set<CGEventType> = []
        if settings.showsKeystrokes { types.insert(.keyDown) }
        if settings.showsClicks { types.formUnion([.leftMouseDown, .rightMouseDown]) }
        return types
    }

    func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        switch type {
        case .keyDown:
            guard !IsSecureEventInputEnabled() else { return .pass }
            let modifiers = KeyModifiers(event.flags).subtracting(.function)
            if settings.onlyShortcuts, modifiers.intersection([.command, .control, .option]).isEmpty { return .pass }
            let combo = KeyCombo(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: modifiers)
            push(combo.displayString)
        case .leftMouseDown, .rightMouseDown:
            let ripple = PresentationModel.Ripple(point: event.location, isRight: type == .rightMouseDown)
            model.ripples.append(ripple)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.model.ripples.removeAll { $0.id == ripple.id }
            }
        default:
            break
        }
        return .pass
    }

    private func push(_ text: String) {
        model.keystrokes.append(text)
        if model.keystrokes.count > 4 { model.keystrokes.removeFirst(model.keystrokes.count - 4) }
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.model.keystrokes.removeAll() }
        }
    }
}

private struct PresentationView: View {
    let model: PresentationModel
    let screenFrame: CGRect

    var body: some View {
        ZStack {
            Color.clear
            if model.highlightsCursor, screenFrame.contains(model.cursor) {
                Circle()
                    .fill(Color.yellow.opacity(0.22))
                    .overlay(Circle().strokeBorder(Color.yellow.opacity(0.75), lineWidth: 2))
                    .frame(width: 64, height: 64)
                    .position(x: model.cursor.x - screenFrame.minX, y: model.cursor.y - screenFrame.minY)
                    .animation(.interactiveSpring(response: 0.12), value: model.cursor)
            }
            ForEach(model.ripples.filter { screenFrame.contains($0.point) }) { ripple in
                RippleView(color: ripple.isRight ? .orange : .accentColor)
                    .position(x: ripple.point.x - screenFrame.minX, y: ripple.point.y - screenFrame.minY)
            }
            if !model.keystrokes.isEmpty, isMouseScreen {
                HStack(spacing: 8) {
                    ForEach(Array(model.keystrokes.enumerated()), id: \.offset) { index, text in
                        Text(text)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .keystivoPanelBackground(cornerRadius: 14)
                            .opacity(index == model.keystrokes.count - 1 ? 1 : 0.55)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.65), value: model.keystrokes)
                .position(x: screenFrame.width / 2, y: screenFrame.height - 120)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
    }

    private var isMouseScreen: Bool {
        guard let screen = NSScreen.underMouse else { return true }
        return ScreenGeometry.frameAX(of: screen) == screenFrame
    }
}

private struct RippleView: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 3)
            .frame(width: expanded ? 70 : 12, height: expanded ? 70 : 12)
            .opacity(expanded ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { expanded = true } }
    }
}
