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

/// Receives links when Keystivo is the default browser and routes them
/// ("Velja / Choosy"). The picker shows installed browsers with number keys.
final class LinkRoutingController {
    private unowned let runtime: KeystivoRuntime
    private var panel: FloatingPanel?
    private let model = LinkPickerModel()
    private var keyMonitor: Any?

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: string) else { return }
        if url.scheme?.lowercased() == "keystivo" {
            runtime.automationSources.handle(url)
            return
        }
        let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        let source = senderPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        route(url, sourceBundleID: source)
    }

    /// Handles file URLs (html) opened through Keystivo as well.
    func open(urls: [URL]) {
        for url in urls { route(url, sourceBundleID: nil) }
    }

    func route(_ incoming: URL, sourceBundleID: String?) {
        let settings = runtime.config.links
        let url = settings.stripsTrackingParameters ? LinkRouter.clean(incoming) : incoming
        let forcePicker = settings.optionShowsPicker && NSEvent.modifierFlags.contains(.option)
        let decision = settings.isEnabled
            ? LinkRouter.resolve(url, sourceBundleID: sourceBundleID, settings: settings, forcePicker: forcePicker)
            : (settings.defaultBrowserBundleID.map(LinkRouter.Decision.open) ?? .ask)
        switch decision {
        case .open(let bundleID): LinkRouter.open(url, inBrowser: bundleID)
        case .ask: showPicker(for: url, source: sourceBundleID)
        }
    }

    private func showPicker(for url: URL, source: String?) {
        model.url = url
        model.sourceBundleID = source
        model.browsers = LinkRouter.installedBrowsers()
        model.remember = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let width = CGFloat(max(model.browsers.count, 3)) * 86 + 32
        panel.setContentSize(CGSize(width: min(width, 760), height: 190))
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(CGPoint(x: mouse.x - panel.frame.width / 2, y: mouse.y - panel.frame.height - 12))
        panel.presentAnimated(makeKey: true)
        NSApp.activate()
        installKeys()
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(activating: true, level: .modalPanel)
        panel.host(LinkPickerView(model: model) { [weak self] browser in self?.choose(browser) }, size: CGSize(width: 400, height: 190))
        panel.onResignKey = { [weak self] in DispatchQueue.main.async { self?.close() } }
        return panel
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.close(); return nil }
            if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit), self.model.browsers.indices.contains(digit - 1) {
                self.choose(self.model.browsers[digit - 1])
                return nil
            }
            if event.keyCode == UInt16(kVK_Return), let first = self.model.browsers.first { self.choose(first); return nil }
            return event
        }
    }

    private func choose(_ browser: BrowserInfo) {
        guard let url = model.url else { return }
        if model.remember, let host = url.host() {
            runtime.config.links.rules.append(LinkRule(hostPattern: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, browserBundleID: browser.bundleID))
        }
        close()
        LinkRouter.open(url, inBrowser: browser.bundleID)
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.dismissAnimated()
    }
}

@Observable
final class LinkPickerModel {
    var url: URL?
    var sourceBundleID: String?
    var browsers: [BrowserInfo] = []
    var remember = false
}

private struct LinkPickerView: View {
    @Bindable var model: LinkPickerModel
    let onChoose: (BrowserInfo) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                Text(model.url?.absoluteString ?? "").lineLimit(1).truncationMode(.middle)
                if let source = model.sourceBundleID {
                    Text("· " + (AppDisplayName.name(forBundleID: source) ?? source)).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            HStack(spacing: 10) {
                ForEach(Array(model.browsers.enumerated()), id: \.element.id) { index, browser in
                    BrowserButton(browser: browser, number: index + 1) { onChoose(browser) }
                }
            }
            Toggle(L("links.remember", model.url?.host() ?? ""), isOn: $model.remember)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .keystivoPanelBackground()
        .overlay(GlowBorder())
    }
}

private struct BrowserButton: View {
    let browser: BrowserInfo
    let number: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                AppIconView(path: browser.url.path, size: 48)
                    .scaleEffect(hovering ? 1.12 : 1)
                    .shadow(color: .black.opacity(hovering ? 0.3 : 0), radius: 8, y: 3)
                Text(browser.name).font(.caption2).lineLimit(1)
                if number <= 9 { Text("\(number)").font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
    }
}
