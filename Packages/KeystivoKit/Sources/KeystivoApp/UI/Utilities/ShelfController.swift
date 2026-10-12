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
import UniformTypeIdentifiers

/// A floating shelf for dragged files and text (Yoink / Dropover style).
///
/// With "show on drag" enabled, a drag that carries files makes the shelf slide
/// in at the right edge of the screen; drop onto it, then drag items out later.
final class ShelfController {
    private var panel: FloatingPanel?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var hideTask: Task<Void, Never>?

    func apply(showOnDrag: Bool) {
        if showOnDrag { installDragMonitor() } else { removeDragMonitor() }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let screen = NSScreen.underMouse else { return }
        let size = CGSize(width: 240, height: 340)
        panel.setContentSize(size)
        panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - size.width - 12, y: screen.visibleFrame.midY - size.height / 2))
        if !panel.isVisible { panel.presentAnimated(makeKey: false, rise: 0) }
    }

    func hide() {
        panel?.dismissAnimated()
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .floating)
        panel.acceptsKey = false
        panel.host(ShelfView(onClose: { [weak self] in self?.hide() }), size: CGSize(width: 240, height: 340))
        return panel
    }

    // MARK: Drag detection

    private func installDragMonitor() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragged() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragEnded() }
        }
    }

    private func removeDragMonitor() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        dragMonitor = nil
        upMonitor = nil
    }

    /// Appears when a file drag reaches the left or right edge of a screen (Yoink-style),
    /// not on every drag (moving files inside Finder shouldn't pop it up).
    private func dragged() {
        guard !isVisible else { return }
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }),
              location.x <= screen.frame.minX + 6 || location.x >= screen.frame.maxX - 6 else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != lastDragChangeCount else { return }
        let types = pasteboard.types ?? []
        guard types.contains(.fileURL) else { return }
        lastDragChangeCount = pasteboard.changeCount
        show()
    }

    private func dragEnded() {
        guard isVisible, ShelfStore.shared.items.isEmpty else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, ShelfStore.shared.items.isEmpty else { return }
            self?.hide()
        }
    }
}

private struct ShelfView: View {
    let onClose: () -> Void
    @State private var isTargeted = false

    var body: some View {
        let store = ShelfStore.shared
        VStack(spacing: 8) {
            HStack {
                Label(L("shelf.title"), systemImage: "tray.full").font(.callout.weight(.semibold))
                Spacer()
                if !store.items.isEmpty {
                    Button { store.clear() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("shelf.clear"))
                }
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless)
            }
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 30, weight: .light))
                        .symbolEffect(.bounce, value: isTargeted)
                    Text(L("shelf.dropHere")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.items) { item in
                            ShelfRow(item: item)
                        }
                    }
                }
                if store.fileURLs.count > 1 {
                    Text(L("shelf.dragAll")).font(.caption2).foregroundStyle(.secondary)
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
                        .onDrag { Self.provider(for: store.fileURLs) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keystivoPanelBackground(cornerRadius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).opacity(isTargeted ? 1 : 0))
        .scaleEffect(isTargeted ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .onDrop(of: [.fileURL, .plainText], isTargeted: $isTargeted) { providers in
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in ShelfStore.shared.add(urls: [url]) }
                    }
                } else {
                    _ = provider.loadObject(ofClass: String.self) { text, _ in
                        guard let text else { return }
                        Task { @MainActor in ShelfStore.shared.add(text: text) }
                    }
                }
            }
            return true
        }
    }

    static func provider(for urls: [URL]) -> NSItemProvider {
        let provider = NSItemProvider()
        for url in urls {
            provider.registerFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                completion(url, false, nil)
                return nil
            }
        }
        return urls.count == 1 ? (NSItemProvider(contentsOf: urls[0]) ?? provider) : provider
    }
}

private struct ShelfRow: View {
    let item: ShelfItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let url = item.url {
                Image(nsImage: AppIconCache.shared.icon(forPath: url.path)).resizable().frame(width: 28, height: 28)
            } else {
                SymbolTile(symbol: "text.quote", color: .orange, size: 26)
            }
            Text(item.title).font(.caption).lineLimit(2)
            Spacer(minLength: 0)
            if hovering {
                Button { ShelfStore.shared.remove(item) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .onHover { hovering = $0 }
        .onDrag {
            if let url = item.url { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            return NSItemProvider(object: (item.text ?? "") as NSString)
        }
    }
}
