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
import KeystivoScreenSaver
import KeystivoSearch
import KeystivoSystem
import KeystivoTools
import KeystivoWindows

/// Actions for the utilities that replace common paid Mac apps.
extension BuiltinActions {
    static func registerUtilityActions(runtime: KeystivoRuntime) {
        // Screen tools (TextSniper, Shottr, Sip)
        register("tools.captureText", "text.viewfinder", .system, keywords: ["ocr", "text from screen", "scan", "qr", "copy text"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.screenTools.captureText()
        }
        register("tools.captureImage", "camera.viewfinder", .system, keywords: ["screenshot", "capture", "clipboard"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.screenTools.captureImage(pin: false)
        }
        register("tools.captureWindow", "macwindow", .system, keywords: ["screenshot", "window", "capture", "shadow"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.screenTools.captureImage(pin: false, mode: .window)
        }
        register("tools.captureScreen", "display", .system, keywords: ["screenshot", "full screen", "capture", "display"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.screenTools.captureImage(pin: false, mode: .screen)
        }
        register("tools.captureDelayed", "timer", .system, keywords: ["screenshot", "timer", "delay", "self-timer", "capture"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.screenTools.captureImage(pin: false, mode: .screen, delay: 5)
        }
        register("tools.captureHistory", "photo.stack", .system, keywords: ["screenshot", "history", "recent", "captures"]) { _, _ in
            runtime.launcher.show(mode: .captures)
        }
        register("tools.annotate", "pencil.tip.crop.circle", .system, keywords: ["annotate", "markup", "arrow", "screenshot", "cleanshot", "blur", "redact"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.screenTools.annotate()
        }
        register("tools.annotateClipboard", "photo.badge.plus", .system, keywords: ["annotate", "markup", "clipboard", "image", "edit"]) { _, _ in
            runtime.screenTools.annotateClipboard()
        }
        register("tools.recordScreen", "record.circle", .system, keywords: ["record", "screen recording", "video", "screencast", "capture video"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.recording.toggle()
        }
        register("tools.pinScreenshot", "pin.square", .system, keywords: ["pin", "float", "screenshot", "reference"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.screenTools.captureImage(pin: true)
        }
        register("tools.pickColor", "eyedropper", .system, keywords: ["color", "hex", "picker", "eyedropper"]) { _, _ in
            try await Task.sleep(for: .milliseconds(120))
            await runtime.screenTools.pickColor()
        }

        // Finder extras
        register("finder.newFile", "doc.badge.plus", .system, keywords: ["new file", "create file", "txt", "finder"]) { _, _ in
            try FinderBridge.newFile()
        }
        register("finder.openTerminal", "terminal", .system, keywords: ["terminal here", "shell", "finder"]) { _, _ in
            try FinderBridge.openCurrentFolder(withBundleID: "com.apple.Terminal")
        }
        register("finder.openEditor", "chevron.left.forwardslash.chevron.right", .system, keywords: ["vs code", "editor", "code here", "finder"]) { _, _ in
            let editors = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.apple.dt.Xcode"]
            guard let editor = editors.first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) else {
                throw ActionError.notAvailable(L("finder.error.noEditor"))
            }
            try FinderBridge.openCurrentFolder(withBundleID: editor)
        }
        register("finder.copyPath", "doc.on.clipboard", .system, keywords: ["copy path", "finder", "posix"]) { _, _ in
            let text = try FinderBridge.copySelectedPaths()
            runtime.hud.show(symbol: "doc.on.clipboard", text: text.components(separatedBy: "\n").first ?? text)
        }

        // Files (AppCleaner, Yoink, Hazel)
        register("files.uninstallApp", "trash.square", .apps, keywords: ["uninstall", "remove app", "delete app", "cleaner"]) { _, _ in
            runtime.windowsUI.showUninstaller()
        }
        register("files.toggleShelf", "tray.full", .workspace, keywords: ["shelf", "drop", "yoink", "temporary"]) { _, _ in
            runtime.shelf.toggle()
        }
        register("files.runRules", "folder.badge.gearshape", .automation, keywords: ["hazel", "organize", "folder rules", "downloads"]) { _, _ in
            FolderRuleEngine.shared.runAll()
            runtime.hud.show(symbol: "folder.badge.gearshape", text: L("folderRules.ran"))
        }

        // Menu bar & monitoring (Bartender, iStat Menus)
        register("menubar.toggleHidden", "menubar.arrow.up.rectangle", .system, keywords: ["menu bar", "hide icons", "bartender"]) { _, _ in
            runtime.menuBarManager.toggle()
        }
        register("monitor.toggle", "gauge.with.dots.needle.67percent", .system, keywords: ["cpu", "memory", "stats", "monitor", "network speed"]) { _, _ in
            runtime.config.menuBar.showsMonitor.toggle()
        }

        // Displays (BetterDisplay lite)
        register("display.dim", "sun.min", .system, parameters: [
            ParameterSpec("level", "param.level", .number(min: 10, max: 100, step: 5), default: .number(60)),
        ], keywords: ["brightness", "dim", "external monitor"]) { arguments, _ in
            guard let screen = NSScreen.underMouse else { return }
            let level = (arguments.double("level") ?? 60) / 100
            DisplayManager.shared.setDimming(level, for: screen.displayID)
            runtime.hud.show(symbol: "sun.min", text: screen.localizedName, value: level)
        }
        register("display.brightnessUp", "sun.max.fill", .system, keywords: ["brightness", "brighter", "ddc", "external monitor"]) { _, _ in
            BrightnessController.shared.adjust(by: 1.0 / 16)
        }
        register("display.brightnessDown", "sun.min.fill", .system, keywords: ["brightness", "darker", "ddc", "external monitor"]) { _, _ in
            BrightnessController.shared.adjust(by: -1.0 / 16)
        }

        // Screen savers
        register("screensaver.start", "sparkles.tv", .system, keywords: ["screen saver", "screensaver", "clock", "idle", "ekran koruyucu"]) { _, _ in
            ScreenSaverManager.startSystemScreenSaver()
        }
        register("screensaver.preview", "play.rectangle", .system, parameters: [
            ParameterSpec("style", "param.style", .choice(choice(SaverStyle.self) { $0.titleKey }), default: .string(SaverStyle.shuffle.rawValue)),
        ], keywords: ["screen saver", "clock", "flip clock", "aurora", "preview"]) { arguments, _ in
            let style = arguments.string("style").flatMap(SaverStyle.init(rawValue:)) ?? .shuffle
            runtime.screenSavers.showPreview(style)
        }

        // Battery (AlDente)
        register("battery.toggleLimit", "battery.75percent", .system, keywords: ["battery", "charge limit", "aldente", "health"]) { _, _ in
            runtime.config.system.chargeLimit.isEnabled.toggle()
            let settings = runtime.config.system.chargeLimit
            runtime.hud.show(symbol: "battery.75percent", text: settings.isEnabled ? L("battery.limitOn", settings.limit) : L("battery.limitOff"))
        }
        register("battery.topUp", "battery.100percent.bolt", .system, keywords: ["battery", "charge", "full", "100%", "trip"]) { _, _ in
            runtime.chargeLimiter.topUp()
            runtime.hud.show(symbol: "battery.100percent.bolt", text: L("battery.toppingUp"))
        }
        register("display.restoreBrightness", "sun.max", .system, keywords: ["brightness", "reset"]) { _, _ in
            DisplayManager.shared.restoreAll()
        }

        // Windows, input & presentation toggles
        register("windows.toggleDragSnap", "rectangle.and.hand.point.up.left", .windows, keywords: ["drag", "snap", "magnet"]) { _, _ in
            runtime.config.windows.dragSnap.isEnabled.toggle()
            runtime.hud.show(symbol: "rectangle.and.hand.point.up.left", text: L(runtime.config.windows.dragSnap.isEnabled ? "dragSnap.on" : "dragSnap.off"))
        }
        register("windows.toggleFocusFollowsMouse", "cursorarrow.and.square.on.square.dashed", .windows, keywords: ["focus", "follows", "mouse", "hover", "autoraise", "raise"]) { _, _ in
            runtime.config.windows.focusFollowsMouse.isEnabled.toggle()
            runtime.hud.show(symbol: "cursorarrow.and.square.on.square.dashed",
                             text: L(runtime.config.windows.focusFollowsMouse.isEnabled ? "focusFollows.on" : "focusFollows.off"))
        }
        register("input.toggleScrollReverse", "arrow.up.arrow.down", .input, keywords: ["scroll", "reverse", "mouse", "natural"]) { _, _ in
            runtime.config.input.scroll.isEnabled.toggle()
        }
        register("presentation.toggleKeystrokes", "keyboard.badge.eye", .system, keywords: ["keystrokes", "presentation", "screencast", "keycastr"]) { _, _ in
            runtime.config.presentation.showsKeystrokes.toggle()
        }
        register("presentation.toggleCursor", "cursorarrow.rays", .system, keywords: ["cursor", "highlight", "presentation", "spotlight"]) { _, _ in
            runtime.config.presentation.highlightsCursor.toggle()
        }
        register("links.makeDefaultBrowser", "safari", .system, keywords: ["default browser", "links", "velja", "choosy"]) { _, _ in
            try await LinkRouter.becomeDefaultBrowser()
        }
    }
}
