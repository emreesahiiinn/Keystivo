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

/// Transient on-screen feedback ("Left Half", "Volume 40%", "Mic muted").
@Observable
final class HUDController {
    enum Style { case normal, warning }

    struct Content: Equatable {
        var symbol: String
        var text: String
        var value: Double?
        var style: Style
        var id = UUID()
    }

    private(set) var content: Content?
    @ObservationIgnored private var panel: FloatingPanel?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    var isEnabled = true

    func show(symbol: String, text: String, value: Double? = nil, style: Style = .normal) {
        guard isEnabled || style == .warning else { return }
        guard KeystivoRuntime.shared.config.general.showsHUD || style == .warning else { return }
        content = Content(symbol: symbol, text: text, value: value, style: style)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = CGSize(width: 280, height: value == nil ? 64 : 84)
        panel.setContentSize(size)
        if let screen = NSScreen.underMouse {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.14))
        }
        if panel.isVisible, panel.alphaValue > 0.5 {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.presentAnimated(makeKey: false, rise: 14)
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(style == .warning ? 2600 : 1300))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            content = nil
        }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .statusBar)
        panel.acceptsKey = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.host(HUDView(controller: self), size: CGSize(width: 280, height: 64))
        return panel
    }
}

private struct HUDView: View {
    let controller: HUDController

    var body: some View {
        if let content = controller.content {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: content.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(content.style == .warning ? Color.orange : Color.primary)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 30)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: content.id)
                    Text(content.text)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let value = content.value {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.15))
                            Capsule().fill(Color.primary.opacity(0.8))
                                .frame(width: proxy.size.width * min(max(value, 0), 1))
                                .animation(.snappy(duration: 0.2), value: value)
                        }
                    }
                    .frame(height: 6)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .keystivoPanelBackground(cornerRadius: 20)
            .popIn(token: content.id.hashValue)
        }
    }
}
