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

/// OCR, QR, color picking and pinned screenshots.
final class ScreenToolsController {
    private unowned let runtime: KeystivoRuntime
    private var pins: [NSPanel] = []

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    /// Select an area → recognize text and codes → copy (TextSniper).
    func captureText() async {
        do {
            let data = try await ScreenCapture.capture(.area)
            let result = try await ScreenCapture.recognize(data)
            guard !result.isEmpty else {
                runtime.hud.show(symbol: "text.viewfinder", text: L("capture.noText"), style: .warning)
                return
            }
            let text = result.text.isEmpty ? result.barcodes.joined(separator: "\n") : result.text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if let link = result.barcodes.compactMap(URL.init(string:)).first(where: { $0.scheme?.hasPrefix("http") == true }) {
                runtime.hud.show(symbol: "qrcode.viewfinder", text: L("capture.qrFound", link.host() ?? link.absoluteString))
            } else {
                runtime.hud.show(symbol: "text.viewfinder", text: L("capture.copiedText", text.count))
            }
            if runtime.config.tools.ocrShowsResult {
                runtime.launcher.show(pluginOutput: .text(text + (result.barcodes.isEmpty ? "" : "\n\n" + result.barcodes.joined(separator: "\n"))), title: L("action.tools.captureText"))
            }
        } catch ScreenCapture.Failure.cancelled {
            return
        } catch {
            runtime.hud.show(symbol: "exclamationmark.triangle", text: error.localizedDescription, style: .warning)
        }
    }

    /// Select an area → copy the image to the clipboard, optionally pin or annotate it.
    func captureImage(pin: Bool) async {
        guard let data = try? await ScreenCapture.capture(.area), let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        if !pin, runtime.config.tools.annotatesAfterCapture {
            runtime.annotationEditor.open(image)
            return
        }
        runtime.hud.show(symbol: "camera.viewfinder", text: L("capture.copiedImage"))
        if pin || runtime.config.tools.pinsAfterCapture { self.pin(image) }
    }

    /// Select an area → open it in the annotation editor (CleanShot-style).
    func annotate() async {
        guard let data = try? await ScreenCapture.capture(.area), let image = NSImage(data: data) else { return }
        runtime.annotationEditor.open(image)
    }

    /// Annotates the image on the clipboard.
    func annotateClipboard() {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else {
            runtime.hud.show(symbol: "photo", text: L("annotate.noClipboardImage"), style: .warning)
            return
        }
        runtime.annotationEditor.open(image)
    }

    /// Floats a screenshot above all windows (Shottr / CleanShot "pin").
    func pin(_ image: NSImage) {
        let maxSide: CGFloat = 520
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: PinnedImageView(image: image, onAnnotate: { [weak self] in
            self?.runtime.annotationEditor.open(image)
        }) { [weak self, weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            self?.pins.removeAll { $0 === panel }
        })
        panel.center()
        panel.orderFrontRegardless()
        pins.append(panel)
    }

    /// System magnifier color picker → copy in the preferred format (Sip / ColorSlurp).
    func pickColor() async {
        guard let color = await ColorPicker.pick() else { return }
        let text = ColorPicker.string(for: color, format: runtime.config.tools.colorFormat)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        runtime.hud.show(symbol: "eyedropper.full", text: text)
    }
}

private struct PinnedImageView: View {
    let image: NSImage
    let onAnnotate: () -> Void
    let onClose: () -> Void
    @State private var hovering = false
    @State private var opacity = 1.0

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor.opacity(hovering ? 0.8 : 0.25), lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 4) {
                        pinButton("pencil.tip.crop.circle", action: onAnnotate)
                        pinButton("doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([image])
                        }
                        pinButton("square.and.arrow.down") { save() }
                        pinButton("xmark", action: onClose)
                    }
                    .padding(6)
                }
            }
            .opacity(opacity)
            .onHover { hovering = $0 }
            .onTapGesture(count: 2, perform: onClose)
            .contextMenu {
                Button(L("launcher.action.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                Button(L("pin.save")) { save() }
                Button(L("action.tools.annotate"), action: onAnnotate)
                Menu(L("pin.opacity")) {
                    ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { value in
                        Button("\(Int(value * 100))%") { opacity = value }
                    }
                }
                Divider()
                Button(L("common.close"), action: onClose)
            }
    }

    private func pinButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.55)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Keystivo Capture.png"
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
