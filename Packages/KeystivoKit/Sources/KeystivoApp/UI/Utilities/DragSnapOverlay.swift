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

/// Shows where a dragged window will land (Magnet-style footprint).
final class DragSnapOverlay {
    private var panel: FloatingPanel?
    private let model = DragSnapPreviewModel()

    init() {
        DragSnapEngine.shared.onPreviewChange = { [weak self] frame, screen in
            self?.update(frame: frame, screen: screen)
        }
        EventTapManager.shared.add(DragSnapEngine.shared)
    }

    private func update(frame: CGRect?, screen: NSScreen?) {
        guard let frame else {
            model.isVisible = false
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Panel covers the target frame (converted to Cocoa coordinates).
        let cocoa = ScreenGeometry.toCocoa(frame)
        let wasVisible = panel.isVisible
        panel.setFrame(cocoa, display: true, animate: wasVisible)
        model.isVisible = true
        model.token += 1
        if !wasVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .floating)
        panel.acceptsKey = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.host(DragSnapPreviewView(model: model), size: CGSize(width: 200, height: 200))
        return panel
    }
}

@Observable
final class DragSnapPreviewModel {
    var isVisible = false
    var token = 0
}

private struct DragSnapPreviewView: View {
    let model: DragSnapPreviewModel

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2.5))
            .keystivoPanelBackground(cornerRadius: 14)
            .padding(6)
            .popIn(token: model.token)
            .opacity(model.isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: model.isVisible)
    }
}
