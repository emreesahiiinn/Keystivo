import AppKit
import KeystivoCore
import KeystivoTools
import SwiftUI

/// CleanShot-style quick access: after a screenshot, a thumbnail waits in the
/// bottom-left corner. Drag it into any app, or copy, save, annotate, pin or
/// dismiss it. It slides away on its own unless the pointer is over it.
final class QuickAccessOverlay {
    private unowned let runtime: KeystivoRuntime
    private var panels: [NSPanel] = []

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    func show(_ image: NSImage, file: URL) {
        guard let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        let width: CGFloat = 220
        let aspect = image.size.height / max(image.size.width, 1)
        let size = CGSize(width: width, height: min(max(width * aspect, 90), 260))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        let model = QuickAccessModel()
        panel.contentView = NSHostingView(rootView: QuickAccessView(image: image, file: file, model: model, actions: actions(image: image, file: file, panel: panel)))
        // Newer thumbnails stack above older ones.
        let visible = screen.visibleFrame
        let offset = panels.reduce(CGFloat(0)) { $0 + $1.frame.height + 12 }
        panel.setFrameOrigin(NSPoint(x: visible.minX + 20, y: visible.minY + 20 + offset))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        panels.append(panel)
        model.onExpire = { [weak self, weak panel] in
            guard let panel else { return }
            self?.dismiss(panel)
        }
        model.startTimer()
    }

    private func actions(image: NSImage, file: URL, panel: NSPanel) -> QuickAccessActions {
        QuickAccessActions(
            copy: { [weak self, weak panel] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                self?.runtime.hud.show(symbol: "doc.on.doc", text: L("capture.copiedImage"))
                if let panel { self?.dismiss(panel) }
            },
            save: { [weak self, weak panel] in
                let folderPath = self?.runtime.config.tools.screenshotFolder ?? ""
                let folder = folderPath.isEmpty
                    ? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                    : URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
                let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
                let destination = folder.appendingPathComponent(L("capture.fileName", stamp) + ".png")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file, to: destination)
                    self?.runtime.hud.show(symbol: "square.and.arrow.down", text: L("capture.savedImage", destination.lastPathComponent))
                } catch {
                    self?.runtime.hud.show(symbol: "exclamationmark.triangle", text: L("capture.saveFailed"), style: .warning)
                }
                if let panel { self?.dismiss(panel) }
            },
            annotate: { [weak self, weak panel] in
                self?.runtime.annotationEditor.open(image)
                if let panel { self?.dismiss(panel) }
            },
            pin: { [weak self, weak panel] in
                self?.runtime.screenTools.pin(image)
                if let panel { self?.dismiss(panel) }
            },
            close: { [weak self, weak panel] in
                if let panel { self?.dismiss(panel) }
            }
        )
    }

    private func dismiss(_ panel: NSPanel) {
        guard let index = panels.firstIndex(of: panel) else { return }
        panels.remove(at: index)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX - 40, y: panel.frame.minY))
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        // Close the gap left in the stack.
        var y = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame.minY ?? 0
        y += 20
        for remaining in panels {
            remaining.animator().setFrameOrigin(NSPoint(x: remaining.frame.minX, y: y))
            y += remaining.frame.height + 12
        }
    }
}

struct QuickAccessActions {
    let copy: () -> Void
    let save: () -> Void
    let annotate: () -> Void
    let pin: () -> Void
    let close: () -> Void
}

@Observable
final class QuickAccessModel {
    var isHovering = false {
        didSet { isHovering ? timer?.cancel() : startTimer() }
    }
    @ObservationIgnored var onExpire: (() -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?

    func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.onExpire?()
        }
    }
}

private struct QuickAccessView: View {
    let image: NSImage
    let file: URL
    let model: QuickAccessModel
    let actions: QuickAccessActions

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            if model.isHovering {
                Color.black.opacity(0.45)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        button("doc.on.doc", L("launcher.action.copy"), actions.copy)
                        button("square.and.arrow.down", L("quickAccess.save"), actions.save)
                    }
                    HStack(spacing: 8) {
                        button("pencil.tip.crop.circle", L("quickAccess.annotate"), actions.annotate)
                        button("pin", L("quickAccess.pin"), actions.pin)
                    }
                }
                VStack {
                    HStack {
                        Spacer()
                        Button(action: actions.close) {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white.opacity(0.9))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        .onHover { model.isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: model.isHovering)
        // Drag the screenshot straight into Mail, Slack, Finder…
        .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
    }

    private func button(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 40, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.2)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
