#if DEBUG
import AppKit
import KeystivoCore
import KeystivoScreenSaver
import SwiftUI

/// `-KSSmokeTest /path/log.txt`: walks through every surface of Keystivo —
/// all settings pages in every language, widgets, screen savers, the menu bar
/// panels, the launcher in each mode, switcher, hints, editors — and logs each
/// step before taking it (flushed), so a crash shows exactly where it happened.
///
/// Settings are changed in memory only (saving is suspended), launcher actions
/// are inert, and nothing is clicked, typed, deleted or sent.
enum SmokeTest {
    static func run(runtime: KeystivoRuntime, output: URL) async {
        let log = SmokeLog(url: output)
        runtime.store.suspendsSaving = true
        let started = Date.now
        log.write("start")

        await settingsPages(runtime: runtime, log: log)
        await widgets(runtime: runtime, log: log)
        await screenSavers(log: log)
        await panels(runtime: runtime, log: log)
        await launcher(runtime: runtime, log: log)
        await overlays(runtime: runtime, log: log)
        configurationRobustness(runtime: runtime, log: log)
        actionDescriptors(log: log)

        log.write("done in \(Int(Date.now.timeIntervalSince(started))) s")
    }

    // MARK: Offscreen rendering

    /// A borderless window far outside every display: SwiftUI lays out and
    /// draws into it, but nobody sees it and it never takes focus.
    private static let stage: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: -40_000, y: -40_000, width: 1000, height: 1800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }()

    private static func render<Content: View>(_ view: Content, size: CGSize, settle: Double = 0.2) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).localizedRoot())
        stage.setContentSize(size)
        stage.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()
        stage.displayIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Steps

    private static func settingsPages(runtime: KeystivoRuntime, log: SmokeLog) async {
        let original = Localizer.shared.preference
        let navigation = SettingsNavigation()
        for language in AppLanguage.supportedCodes {
            Localizer.shared.setPreference(language)
            for section in SettingsSection.allCases {
                log.write("settings \(language) \(section.rawValue)")
                navigation.selection = section
                await render(SettingsRootView(runtime: runtime, navigation: navigation).page(for: section), size: CGSize(width: 760, height: 1800), settle: 0.12)
            }
        }
        // The whole window once, sidebar included.
        Localizer.shared.setPreference("tr")
        log.write("settings window")
        await render(SettingsRootView(runtime: runtime, navigation: navigation), size: CGSize(width: 1000, height: 700), settle: 0.4)
        Localizer.shared.setPreference(original)
    }

    private static func widgets(runtime: KeystivoRuntime, log: SmokeLog) async {
        for kind in WidgetKind.allCases {
            for size in kind.sizes {
                log.write("widget \(kind.rawValue) \(size.rawValue)")
                let instance = WidgetInstance(kind: kind, size: size)
                await render(WidgetView(runtime: runtime, instance: instance).padding(14).panelSurface(.glass, cornerRadius: 22), size: size.points)
            }
        }
        // Real desktop panels: on top, then gone again.
        log.write("desktop widgets apply")
        var demo = WidgetSettings()
        demo.alwaysOnTop = true
        demo.instances = [WidgetInstance(kind: .clock), WidgetInstance(kind: .system), WidgetInstance(kind: .notes, size: .medium)]
        runtime.desktopWidgets.apply(demo)
        await pause(1.2)
        demo.instances[0].size = .medium
        demo.instances.remove(at: 1)
        log.write("desktop widgets update")
        runtime.desktopWidgets.apply(demo)
        await pause(0.6)
        log.write("desktop widgets clear")
        runtime.desktopWidgets.apply(WidgetSettings())
        runtime.desktopWidgets.apply(runtime.config.widgets)
    }

    private static func screenSavers(log: SmokeLog) async {
        for style in SaverStyle.allCases {
            for backdrop in SaverBackdrop.allCases {
                log.write("saver \(style.rawValue) \(backdrop.rawValue)")
                await render(SaverRootView(style: style, isPreview: true, backdrop: backdrop), size: CGSize(width: 480, height: 300), settle: 0.15)
            }
        }
    }

    private static func panels(runtime: KeystivoRuntime, log: SmokeLog) async {
        log.write("control center show")
        runtime.controlCenter.show()
        await pause(1)
        log.write("control center close/reopen")
        runtime.controlCenter.close()
        runtime.controlCenter.show()
        await pause(0.8)
        runtime.controlCenter.close()
        await pause(0.4)
        log.write("control center offscreen with every module")
        let saved = runtime.config.menuBar.controlCenter
        runtime.config.menuBar.controlCenter.modules = ControlCenterModule.allCases
        runtime.config.menuBar.controlCenter.toggles = ControlCenterToggle.allCases
        runtime.config.widgets.instances.append(WidgetInstance(kind: .clock, placement: .panel))
        await render(ControlCenterView(runtime: runtime), size: CGSize(width: 332, height: 1300), settle: 0.4)
        runtime.config.widgets.instances.removeLast()
        runtime.config.menuBar.controlCenter = saved
        log.write("mixer panel")
        runtime.mixerItem.show()
        await pause(0.8)
        runtime.mixerItem.close()
        await render(MixerPanelView(runtime: runtime), size: CGSize(width: 320, height: 600), settle: 0.3)
        await pause(0.3)
    }

    private static func launcher(runtime: KeystivoRuntime, log: SmokeLog) async {
        let model = runtime.launcher.model
        model.isInertForTesting = true
        defer { model.isInertForTesting = false }
        let queries = ["", "a", "safari", "2+2*3", "(1/0)", "100 usd to try", "5 km to mi", "tokyo time", "kalp", "define test",
                       "😀🇹🇷 é ç", String(repeating: "ğ", count: 300), "%@ %d \\ \" '", "sys", "settings"]
        let modes: [(String, LauncherMode)] = [("root", .root), ("clipboard", .clipboard), ("snippets", .snippets), ("files", .files),
                                               ("windows", .windows), ("emoji", .emoji), ("menuItems", .menuItems),
                                               ("processes", .processes), ("schedule", .schedule), ("captures", .captures)]
        for (name, mode) in modes {
            log.write("launcher \(name)")
            runtime.launcher.show(mode: mode)
            await pause(0.5)
            for query in (mode == .root ? queries : ["", "a", "test", "😀"]) {
                log.write("launcher \(name) query \(query.prefix(24))")
                model.query = query
                await pause(mode == .root ? 0.35 : 0.25)
                model.moveSelection(1)
                model.moveSelection(-3)
                model.moveSelection(40)
            }
            runtime.launcher.hide()
            await pause(0.3)
        }
        log.write("launcher plugin output")
        runtime.launcher.show(pluginOutput: .text("Smoke test\nline 2"), title: "Test")
        await pause(0.5)
        runtime.launcher.hide()
        await pause(0.3)
    }

    private static func overlays(runtime: KeystivoRuntime, log: SmokeLog) async {
        log.write("hud")
        runtime.hud.show(symbol: "checkmark.circle.fill", text: "Smoke test")
        runtime.hud.show(symbol: "speaker.wave.2.fill", text: "Volume", value: 0.4)
        runtime.hud.show(symbol: "exclamationmark.triangle", text: "Warning", style: .warning)
        await pause(0.6)

        log.write("switcher open")
        await runtime.switcher.toggle(scope: .all, holdModifiers: [])
        await pause(0.8)
        log.write("switcher close")
        runtime.switcher.close()
        await pause(0.3)

        for mode in [HintMode.click, .scroll] {
            log.write("hints \(mode)")
            await runtime.hints.start(mode: mode)
            await pause(0.8)
            runtime.hints.stop()
            await pause(0.3)
        }

        log.write("annotation editor")
        let image = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        runtime.annotationEditor.open(image)
        await pause(0.8)
        for window in NSApp.windows where window.title == L("annotate.title") { window.close() }

        log.write("quick access overlay")
        let file = FileManager.default.temporaryDirectory.appending(path: "keystivo-smoke.png")
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: file)
            runtime.quickAccess.show(image, file: file)
        }
        await pause(0.6)

        log.write("onboarding window")
        runtime.windowsUI.showOnboarding()
        await pause(0.8)
        log.write("uninstaller window")
        runtime.windowsUI.showUninstaller()
        await pause(0.8)
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) { window.close() }
        runtime.applyActivationPolicy()
        await pause(0.3)
    }

    /// Damaged settings files must load (or fall back), never crash.
    private static func configurationRobustness(runtime: KeystivoRuntime, log: SmokeLog) {
        log.write("config robustness")
        guard let data = try? JSONFileStore<KeystivoConfiguration>.encoder.encode(runtime.config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var variants: [Any] = [[String: Any](), [], "text", 42, NSNull()]
        for key in root.keys {
            var removed = root
            removed[key] = nil
            variants.append(removed)
            var wrong = root
            wrong[key] = "wrong"
            variants.append(wrong)
            if let section = root[key] as? [String: Any] {
                for child in section.keys {
                    var nested = section
                    nested[child] = [1, 2, 3]
                    var copy = root
                    copy[key] = nested
                    variants.append(copy)
                }
            }
        }
        var loaded = 0
        for variant in variants {
            guard let data = try? JSONSerialization.data(withJSONObject: variant, options: [.fragmentsAllowed]) else { continue }
            if (try? ConfigurationStore.decodeTolerantly(data)) != nil { loaded += 1 }
        }
        log.write("config robustness: \(variants.count) damaged files, \(loaded) still loaded, none crashed")
        // Malformed export files: rejected with an error, never an exception.
        let imports: [String] = [
            #"{"format":"com.keystivo.configuration","configuration":"text"}"#,
            #"{"format":"com.keystivo.configuration","configuration":42}"#,
            #"{"format":"com.keystivo.configuration","configuration":null}"#,
            #"{"format":"com.keystivo.configuration","configuration":[1,2]}"#,
            #"{"format":"com.keystivo.configuration","configuration":{"general":{"language":5}}}"#,
            #"["not","an","object"]"#,
        ]
        var rejected = 0
        for text in imports where (try? runtime.store.previewImport(Data(text.utf8))) == nil { rejected += 1 }
        log.write("import robustness: \(imports.count) malformed files, \(rejected) rejected, none crashed")
    }

    /// Every action has a title and a symbol that exists.
    private static func actionDescriptors(log: SmokeLog) {
        var problems: [String] = []
        for descriptor in ActionRegistry.shared.descriptors.values.sorted(by: { $0.id < $1.id }) {
            if L(descriptor.titleKey) == descriptor.titleKey { problems.append("no title: \(descriptor.id)") }
            if NSImage(systemSymbolName: descriptor.symbolName, accessibilityDescription: nil) == nil { problems.append("no symbol \(descriptor.symbolName): \(descriptor.id)") }
        }
        log.write("actions: \(ActionRegistry.shared.descriptors.count), problems: \(problems.isEmpty ? "none" : problems.joined(separator: "; "))")
    }
}

/// Appends lines to a file and flushes each one.
private final class SmokeLog {
    private let handle: FileHandle?

    init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        let stamp = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        handle?.write(Data("\(stamp) \(line)\n".utf8))
        try? handle?.synchronize()
    }
}
#endif
