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

// MARK: - Audio

extension BuiltinActions {
    static func registerAudioActions(runtime: KeystivoRuntime) {
        let devices = AudioDeviceManager.shared
        let apps = AppAudioController.shared
        func step() -> Float { Float(runtime.config.audio.volumeStep) }
        func showVolume() {
            let symbol = devices.outputMuted || devices.outputVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
            runtime.hud.show(symbol: symbol, text: devices.defaultOutput?.name ?? L("audio.output"), value: devices.outputMuted ? 0 : Double(devices.outputVolume))
        }
        register("audio.volumeUp", "speaker.plus", .audio, keywords: ["louder", "volume"]) { _, _ in
            devices.adjustOutputVolume(by: step())
            showVolume()
        }
        register("audio.volumeDown", "speaker.minus", .audio, keywords: ["quieter", "volume"]) { _, _ in
            devices.adjustOutputVolume(by: -step())
            showVolume()
        }
        register("audio.toggleMute", "speaker.slash", .audio, keywords: ["mute", "silence"]) { _, _ in
            devices.toggleOutputMute()
            showVolume()
        }
        register("audio.setVolume", "speaker.wave.3", .audio, parameters: [
            ParameterSpec("level", "param.level", .number(min: 0, max: 100, step: 5), default: .number(50)),
        ], launcher: false) { arguments, _ in
            devices.setOutputVolume(Float((arguments.double("level") ?? 50) / 100))
            showVolume()
        }
        register("audio.cycleOutput", "hifispeaker.2", .audio, keywords: ["output", "speaker", "headphones", "device"]) { _, _ in
            try devices.cycleOutput()
            runtime.hud.show(symbol: devices.defaultOutput?.symbolName ?? "hifispeaker", text: devices.defaultOutput?.name ?? "")
        }
        register("audio.setOutput", "hifispeaker", .audio, parameters: [
            ParameterSpec("device", "param.device", .dynamicChoice("audioOutputs")),
        ], launcher: false) { arguments, _ in
            try devices.setDefaultOutput(uid: try arguments.require("device"))
            runtime.hud.show(symbol: devices.defaultOutput?.symbolName ?? "hifispeaker", text: devices.defaultOutput?.name ?? "")
        }
        register("audio.setInput", "mic", .audio, parameters: [
            ParameterSpec("device", "param.device", .dynamicChoice("audioInputs")),
        ], launcher: false) { arguments, _ in
            try devices.setDefaultInput(uid: try arguments.require("device"))
        }
        register("audio.toggleMic", "mic.slash", .audio, keywords: ["microphone", "mute mic"]) { _, _ in
            devices.toggleInputMute()
            runtime.hud.show(symbol: devices.inputMuted ? "mic.slash.fill" : "mic.fill", text: L(devices.inputMuted ? "audio.mic.muted" : "audio.mic.live"))
        }
        register("audio.setMicMuted", "mic.slash", .audio, parameters: [
            ParameterSpec("muted", "param.muted", .toggle, default: .bool(true)),
        ], launcher: false) { arguments, _ in
            devices.setInputMuted(arguments.bool("muted") ?? true)
        }
        register("audio.frontAppVolumeUp", "speaker.wave.2.circle", .audio, keywords: ["app volume"]) { _, _ in
            guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
            apps.adjustVolume(by: step(), for: bundleID)
            showAppVolume(bundleID, runtime: runtime)
        }
        register("audio.frontAppVolumeDown", "speaker.minus", .audio, keywords: ["app volume"]) { _, _ in
            guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
            apps.adjustVolume(by: -step(), for: bundleID)
            showAppVolume(bundleID, runtime: runtime)
        }
        register("audio.frontAppToggleMute", "speaker.slash.circle", .audio, keywords: ["mute app"]) { _, _ in
            guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
            apps.toggleMute(for: bundleID)
            showAppVolume(bundleID, runtime: runtime)
        }
        let appParameter = ParameterSpec("bundleID", "param.app", .application)
        register("audio.setAppVolume", "slider.horizontal.3", .audio, parameters: [
            appParameter, ParameterSpec("level", "param.level", .number(min: 0, max: 150, step: 5), default: .number(100)),
        ], launcher: false) { arguments, _ in
            apps.setVolume(Float((arguments.double("level") ?? 100) / 100), for: try arguments.require("bundleID"))
        }
        register("audio.setAppMuted", "speaker.slash", .audio, parameters: [
            appParameter, ParameterSpec("muted", "param.muted", .toggle, default: .bool(true)),
        ], launcher: false) { arguments, _ in
            apps.setMuted(arguments.bool("muted") ?? true, for: try arguments.require("bundleID"))
        }
        register("audio.applyProfile", "slider.vertical.3", .audio, parameters: [
            ParameterSpec("profile", "param.audioProfile", .dynamicChoice("audioProfiles")),
        ], launcher: false) { arguments, _ in
            guard let id = arguments.string("profile").flatMap(UUID.init), let profile = runtime.config.audio.profiles.first(where: { $0.id == id }) else {
                throw ActionError.notAvailable(L("audio.error.profileMissing"))
            }
            AudioProfileApplier.apply(profile)
            runtime.hud.show(symbol: profile.symbolName, text: profile.name)
        }
        register("audio.showMixer", "slider.horizontal.below.square.filled.and.square", .audio, keywords: ["mixer", "app volume", "sound"]) { _, _ in
            runtime.mixer.toggle()
        }
    }

    static func showAppVolume(_ bundleID: String, runtime: KeystivoRuntime) {
        let setting = AppAudioController.shared.setting(for: bundleID)
        let name = AppDisplayName.name(forBundleID: bundleID) ?? bundleID
        runtime.hud.show(symbol: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", text: name, value: setting.muted ? 0 : Double(min(setting.volume, 1.5) / 1.5))
    }
}

// MARK: - Keyboard navigation

extension BuiltinActions {
    static func registerNavigationActions(runtime: KeystivoRuntime) {
        register("navigation.hints", "keyboard.badge.ellipsis", .navigation, keywords: ["click", "hint", "label", "homerow"]) { _, _ in
            try requireAccessibility()
            await runtime.hints.start(mode: .click)
        }
        register("navigation.search", "text.magnifyingglass", .navigation, keywords: ["find element", "search ui"]) { _, _ in
            try requireAccessibility()
            await runtime.hints.start(mode: .search)
        }
        register("navigation.scroll", "scroll", .navigation, keywords: ["scroll", "page"]) { _, _ in
            try requireAccessibility()
            await runtime.hints.start(mode: .scroll)
        }
    }
}

// MARK: - Clipboard & snippets

extension BuiltinActions {
    static func registerClipboardActions(runtime: KeystivoRuntime) {
        let clipboard = ClipboardMonitor.shared
        register("clipboard.history", "clipboard", .clipboard, keywords: ["paste", "history", "copy"]) { _, _ in
            runtime.launcher.show(mode: .clipboard)
        }
        register("clipboard.pastePlain", "doc.plaintext", .clipboard, keywords: ["paste plain", "strip formatting"]) { _, _ in
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            clipboard.markOwnWrite()
            SyntheticInput.paste()
        }
        register("clipboard.togglePause", "pause.circle", .clipboard, keywords: ["pause", "private", "incognito"]) { _, _ in
            clipboard.setPaused(!clipboard.isPaused)
            runtime.hud.show(symbol: clipboard.isPaused ? "pause.circle.fill" : "play.circle.fill", text: L(clipboard.isPaused ? "clipboard.paused" : "clipboard.resumed"))
        }
        register("clipboard.clear", "trash", .clipboard, keywords: ["clear history", "delete"], confirm: true) { _, _ in
            await clipboard.clearHistory()
            runtime.hud.show(symbol: "trash", text: L("clipboard.cleared"))
        }
        register("snippets.show", "text.badge.plus", .clipboard, keywords: ["snippets", "text expansion", "templates"]) { _, _ in
            runtime.launcher.show(mode: .snippets)
        }
        register("snippets.insert", "text.insert", .clipboard, parameters: [
            ParameterSpec("snippet", "param.snippet", .dynamicChoice("snippets")),
        ], launcher: false) { arguments, _ in
            guard let id = arguments.string("snippet").flatMap(UUID.init), let snippet = runtime.config.snippets.snippets.first(where: { $0.id == id }) else {
                throw ActionError.notAvailable(L("snippets.error.missing"))
            }
            await SnippetExpander.insert(snippet.content)
        }
    }

    static func registerLauncherActions(runtime: KeystivoRuntime) {
        register("launcher.show", "magnifyingglass", .launcher, keywords: ["search", "spotlight", "command palette"], launcher: false) { _, _ in
            runtime.launcher.toggle(mode: .root)
        }
        register("launcher.files", "doc.text.magnifyingglass", .launcher, keywords: ["find file", "folder"]) { _, _ in
            runtime.launcher.show(mode: .files)
        }
        register("launcher.windows", "macwindow.badge.plus", .launcher, keywords: ["window title", "find window"]) { _, _ in
            runtime.launcher.show(mode: .windows)
        }
        register("launcher.quickActions", "text.cursor", .launcher, keywords: ["transform", "selected text", "uppercase"]) { _, _ in
            runtime.launcher.show(mode: .textActions)
        }
        register("launcher.emoji", "face.smiling", .launcher, keywords: ["emoji", "symbol", "character", "smiley", "unicode"]) { _, _ in
            runtime.launcher.show(mode: .emoji)
        }
        register("launcher.menuItems", "filemenu.and.selection", .launcher, keywords: ["menu", "menu bar", "command", "search menu"]) { _, _ in
            runtime.launcher.show(mode: .menuItems)
        }
        register("launcher.processes", "cpu", .launcher, keywords: ["kill", "process", "activity monitor", "force quit", "cpu", "memory"]) { _, _ in
            runtime.launcher.show(mode: .processes)
        }
        register("launcher.schedule", "calendar", .launcher, keywords: ["calendar", "schedule", "agenda", "meeting", "events", "today"]) { _, _ in
            runtime.launcher.show(mode: .schedule)
        }
        register("calendar.joinNextMeeting", "video", .launcher, keywords: ["meeting", "join", "zoom", "meet", "teams", "call"]) { _, _ in
            guard await CalendarService.shared.requestAccess() else { throw ActionError.failed(L("schedule.accessDenied")) }
            guard let meeting = CalendarService.shared.nextMeeting(), let link = meeting.meetingURL else {
                runtime.hud.show(symbol: "video.slash", text: L("schedule.noMeeting"))
                return
            }
            NSWorkspace.shared.open(link)
            runtime.hud.show(symbol: "video", text: L("schedule.joining", meeting.title))
        }
        register("app.settings", "gearshape", .system, keywords: ["preferences", "settings", "keystivo"]) { _, _ in
            runtime.windowsUI.showSettings()
        }
        register("app.permissions", "lock.shield", .system, keywords: ["permissions", "privacy", "diagnostics", "errors"]) { _, _ in
            runtime.windowsUI.showSettings(section: .diagnostics)
        }
        register("dock.toggleLauncherBar", "dock.rectangle", .workspace, keywords: ["dock", "bar", "launcher bar"]) { _, _ in
            runtime.config.dock.launcherBar.isEnabled.toggle()
        }
        register("dock.togglePreviews", "rectangle.on.rectangle.angled", .workspace, keywords: ["dock preview"]) { _, _ in
            runtime.config.dock.previewsEnabled.toggle()
        }
    }
}

// MARK: - Workspace & profiles

extension BuiltinActions {
    static func registerWorkspaceActions(runtime: KeystivoRuntime) {
        register("profile.activate", "person.crop.circle", .workspace, parameters: [
            ParameterSpec("profile", "param.profile", .dynamicChoice("profiles")),
        ], launcher: false) { arguments, _ in
            guard let id = arguments.string("profile").flatMap(UUID.init) else { throw ActionError.missingArgument("profile") }
            runtime.profiles.activate(id)
        }
        register("profile.next", "person.2.circle", .workspace, keywords: ["profile", "work", "personal", "switch"]) { _, _ in
            runtime.profiles.activateNext()
        }
        register("focus.start", "moon.circle.fill", .workspace, parameters: [
            ParameterSpec("minutes", "param.minutes", .number(min: 0, max: 240, step: 5), default: .number(25)),
        ], keywords: ["focus", "pomodoro", "distraction", "deep work"]) { arguments, _ in
            FocusController.shared.start(minutes: arguments.int("minutes"))
            runtime.hud.show(symbol: "moon.circle.fill", text: L("focus.started"))
        }
        register("focus.stop", "moon.circle", .workspace, keywords: ["focus", "end"]) { _, _ in
            FocusController.shared.stop()
            runtime.hud.show(symbol: "moon.circle", text: L("focus.stopped"))
        }
        register("focus.toggle", "moon", .workspace, keywords: ["focus"]) { _, _ in
            FocusController.shared.toggle()
            runtime.hud.show(symbol: "moon", text: L(FocusController.shared.isActive ? "focus.started" : "focus.stopped"))
        }
        register("input.selectSource", "globe", .input, parameters: [
            ParameterSpec("source", "param.inputSource", .dynamicChoice("inputSources")),
        ], launcher: false) { arguments, _ in
            InputSourceManager.shared.select(id: try arguments.require("source"))
        }
        register("input.nextSource", "globe", .input, keywords: ["keyboard layout", "input source", "language"]) { _, _ in
            InputSourceManager.shared.selectNext()
            let name = InputSourceManager.shared.sources.first { $0.id == InputSourceManager.shared.currentID }?.name ?? ""
            runtime.hud.show(symbol: "globe", text: name)
        }
        register("gestures.toggleTrackpad", "hand.draw", .input, keywords: ["gestures", "trackpad"]) { _, _ in
            runtime.config.gestures.trackpadEnabled.toggle()
        }
        register("gestures.toggleMouse", "computermouse", .input, keywords: ["mouse gestures"]) { _, _ in
            runtime.config.gestures.mouseEnabled.toggle()
        }
    }
}

// MARK: - System & power

extension BuiltinActions {
    static func registerSystemActions(runtime: KeystivoRuntime) {
        for command in SystemCommand.allCases {
            register("system.\(command.rawValue)", command.symbolName, .system, keywords: [command.rawValue], confirm: command.isDestructive, titleKey: command.titleKey) { _, _ in
                try await SystemCommandRunner.run(command)
                if command == .keepAwake {
                    let on = KeepAwakeController.shared.mode != .off
                    runtime.hud.show(symbol: on ? "cup.and.saucer.fill" : "cup.and.saucer", text: L(on ? "keepAwake.on" : "keepAwake.off"))
                }
            }
        }
        register("power.applyProfile", "bolt.circle", .power, parameters: [
            ParameterSpec("profile", "param.powerProfile", .dynamicChoice("powerProfiles")),
        ], launcher: false) { arguments, _ in
            let id = try arguments.require("profile")
            guard let profile = runtime.config.system.powerProfiles.first(where: { $0.id == id }) else {
                throw ActionError.notAvailable(L("power.error.profileMissing"))
            }
            runtime.applyPowerProfile(profile)
        }
        register("power.keepAwake", "cup.and.saucer", .power, parameters: [
            ParameterSpec("mode", "param.mode", .choice(choice(KeepAwakeMode.self) { $0.titleKey }), default: .string(KeepAwakeMode.system.rawValue)),
            ParameterSpec("minutes", "param.minutes", .number(min: 0, max: 600, step: 15), default: .number(0)),
        ], launcher: false) { arguments, _ in
            let mode = KeepAwakeMode(rawValue: arguments.string("mode") ?? "") ?? .system
            let minutes = arguments.double("minutes") ?? 0
            KeepAwakeController.shared.isSetByProfile = false
            KeepAwakeController.shared.set(mode, duration: minutes > 0 ? minutes * 60 : nil)
        }
        register("system.notify", "bell", .automation, parameters: [
            ParameterSpec("title", "param.title", .text, default: .string("Keystivo")),
            ParameterSpec("body", "param.body", .multilineText, optional: true),
        ], launcher: false) { arguments, _ in
            await Notifier.post(title: arguments.string("title") ?? "Keystivo", body: arguments.string("body") ?? "")
        }
        register("system.showHUD", "text.bubble", .automation, parameters: [
            ParameterSpec("text", "param.text", .text),
        ], launcher: false) { arguments, _ in
            runtime.hud.show(symbol: "info.circle", text: arguments.string("text") ?? "")
        }
        register("system.delay", "hourglass", .automation, parameters: [
            ParameterSpec("seconds", "param.seconds", .number(min: 0, max: 60, step: 0.5), default: .number(1)),
        ], launcher: false) { arguments, _ in
            let seconds = min(max((arguments.double("seconds") ?? 1).finite(or: 1), 0), 3600)
            try await Task.sleep(for: .milliseconds((seconds * 1000).safeInt))
        }
        register("system.typeText", "keyboard", .automation, parameters: [
            ParameterSpec("text", "param.text", .multilineText),
        ], launcher: false) { arguments, _ in
            await SnippetExpander.insert(arguments.string("text") ?? "")
        }
        register("system.pressKeys", "command.square", .automation, parameters: [
            ParameterSpec("keys", "param.keys", .keyCombo),
        ], launcher: false) { arguments, _ in
            guard let combo = arguments.combo("keys") else { throw ActionError.missingArgument("keys") }
            // Let the triggering chord's modifiers be released first.
            try await Task.sleep(for: .milliseconds(60))
            SyntheticInput.pressKey(combo)
        }
        register("system.copyText", "doc.on.doc", .automation, parameters: [
            ParameterSpec("text", "param.text", .multilineText),
        ], launcher: false) { arguments, _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(arguments.string("text") ?? "", forType: .string)
        }
        register("system.openURL", "link", .automation, parameters: [ParameterSpec("url", "param.url", .url)], launcher: false) { arguments, _ in
            guard let url = URL(string: try arguments.require("url")) else { throw ActionError.failed(L("action.error.invalidURL")) }
            NSWorkspace.shared.open(url)
        }
        register("system.runShellScript", "terminal", .automation, parameters: [
            ParameterSpec("script", "param.script", .multilineText),
        ], launcher: false) { arguments, context in
            let output = try await SystemCommandRunner.shell("/bin/zsh", ["-lc", try arguments.require("script")], timeout: .seconds(60))
            context.emit(output)
            if !output.isEmpty, context.source != .workflow { runtime.hud.show(symbol: "terminal", text: String(output.prefix(120))) }
        }
        register("system.runAppleScript", "applescript", .automation, parameters: [
            ParameterSpec("script", "param.script", .multilineText),
        ], launcher: false) { arguments, context in
            let output = try await SystemCommandRunner.appleScript(try arguments.require("script"))
            context.emit(output)
            if !output.isEmpty, context.source != .workflow { runtime.hud.show(symbol: "applescript", text: String(output.prefix(120))) }
        }
        register("system.runShortcut", "square.2.layers.3d", .automation, parameters: [
            ParameterSpec("name", "param.shortcutName", .text),
            ParameterSpec("input", "param.input", .multilineText, optional: true),
        ], launcher: false) { arguments, context in
            let input = arguments.string("input").flatMap { $0.isEmpty ? nil : $0 }
            context.emit(try await SystemCommandRunner.runShortcut(named: try arguments.require("name"), input: input))
        }
        // Keyboard Maestro-style building blocks for workflows.
        register("automation.httpRequest", "network", .automation, parameters: [
            ParameterSpec("url", "param.url", .url),
            ParameterSpec("method", "param.method", .choice([ChoiceOption("GET", "http.get"), ChoiceOption("POST", "http.post"), ChoiceOption("PUT", "http.put"), ChoiceOption("DELETE", "http.delete")]), default: .string("GET")),
            ParameterSpec("body", "param.body", .multilineText, optional: true),
            ParameterSpec("contentType", "param.contentType", .text, default: .string("application/json")),
        ], launcher: false) { arguments, context in
            guard let url = URL(string: try arguments.require("url")), url.scheme?.hasPrefix("http") == true else {
                throw ActionError.failed(L("action.error.invalidURL"))
            }
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.httpMethod = arguments.string("method") ?? "GET"
            if let body = arguments.string("body"), !body.isEmpty, request.httpMethod != "GET" {
                request.httpBody = Data(body.utf8)
                request.setValue(arguments.string("contentType") ?? "application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let text = String(data: data, encoding: .utf8) ?? ""
            if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
                throw ActionError.failed(L("automation.error.http", status, String(text.prefix(200))))
            }
            context.emit(text)
        }
        register("automation.selectMenuItem", "filemenu.and.selection", .automation, parameters: [
            ParameterSpec("path", "param.menuPath", .text),
        ], launcher: false) { arguments, _ in
            guard let app = NSWorkspace.shared.frontmostApplication else { throw ActionError.notAvailable(L("menuItems.failed")) }
            let wanted = try arguments.require("path").split(whereSeparator: { $0 == ">" || $0 == "›" })
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let pid = app.processIdentifier
            // Our own menus must be read on the main thread (AppKit answers in-process requests on the caller's thread).
            let entries = pid == getpid() ? MenuItemCollector.items(pid: pid) : await Task.detached { MenuItemCollector.items(pid: pid) }.value
            // Full path ("File > Export > PDF"), or just the item title when unique.
            let match = entries.first { ($0.path + [$0.title]).map { $0.lowercased() } == wanted }
                ?? entries.first { wanted.count == 1 && $0.title.lowercased() == wanted[0] }
                ?? entries.first { ($0.path + [$0.title]).map { $0.lowercased() }.joined(separator: ">").hasSuffix(wanted.joined(separator: ">")) }
            guard let match, match.isEnabled, match.perform() else {
                throw ActionError.failed(L("automation.error.menuItem", wanted.joined(separator: " › ")))
            }
        }
        register("automation.transformText", "textformat", .automation, parameters: [
            ParameterSpec("text", "param.text", .multilineText, default: .string("{{output}}")),
            ParameterSpec("transform", "param.transform", .choice(TextTransform.allCases.map { ChoiceOption($0.rawValue, $0.titleKey) }), default: .string(TextTransform.uppercase.rawValue)),
        ], launcher: false) { arguments, context in
            guard let transform = arguments.string("transform").flatMap(TextTransform.init(rawValue:)),
                  let result = transform.apply(arguments.string("text") ?? "", locale: Localizer.shared.locale) else {
                throw ActionError.failed(L("automation.error.transform"))
            }
            context.emit(result)
        }
        register("automation.readClipboard", "clipboard", .automation, launcher: false) { _, context in
            context.emit(NSPasteboard.general.string(forType: .string) ?? "")
        }
    }
}

// MARK: - Automation, dynamic items, plugins

extension BuiltinActions {
    static func registerAutomationActions(runtime: KeystivoRuntime) {
        register("workflow.run", "bolt.fill", .automation, parameters: [
            ParameterSpec("workflow", "param.workflow", .dynamicChoice("workflows")),
        ], launcher: false) { arguments, _ in
            guard let id = arguments.string("workflow").flatMap(UUID.init) else { throw ActionError.missingArgument("workflow") }
            try AutomationEngine.shared.run(workflowID: id)
        }
        register("automation.toggle", "bolt.slash", .automation, keywords: ["automation", "pause workflows"]) { _, _ in
            runtime.config.automation.isEnabled.toggle()
            runtime.hud.show(symbol: "bolt", text: L(runtime.config.automation.isEnabled ? "automation.enabled" : "automation.disabled"))
        }
    }

    /// Per-item launcher commands generated from user data (groups, profiles, layouts…).
    static func registerDynamicActions(runtime: KeystivoRuntime) {
        registry.unregister(prefix: "dynamic.")
        for group in runtime.config.workspace.appGroups {
            register("dynamic.group.\(group.id.uuidString)", group.symbolName, .apps, keywords: ["group"] + [group.name], titleKey: L("dynamic.group.open", group.name)) { _, _ in
                try await registry.perform(ActionInvocation("apps.group.focus", arguments: ["group": .string(group.id.uuidString)]), context: ActionContext(source: .launcher))
            }
        }
        for profile in runtime.config.workspace.profiles {
            register("dynamic.profile.\(profile.id.uuidString)", profile.symbolName, .workspace, keywords: ["profile", profile.name], titleKey: L("dynamic.profile.activate", profile.name)) { _, _ in
                runtime.profiles.activate(profile.id)
            }
        }
        for layout in runtime.config.windows.layouts {
            register("dynamic.layout.\(layout.id.uuidString)", "rectangle.3.group", .workspace, keywords: ["layout", layout.name], titleKey: L("dynamic.layout.restore", layout.name)) { _, _ in
                try requireAccessibility()
                await LayoutManager.shared.restore(layout)
            }
        }
        for profile in runtime.config.audio.profiles {
            register("dynamic.audio.\(profile.id.uuidString)", profile.symbolName, .audio, keywords: ["audio profile", profile.name], titleKey: L("dynamic.audio.apply", profile.name)) { _, _ in
                AudioProfileApplier.apply(profile)
            }
        }
        for profile in runtime.config.system.powerProfiles {
            register("dynamic.power.\(profile.id)", profile.symbolName, .power, keywords: ["power", "battery", profile.name], titleKey: L("dynamic.power.apply", profile.name)) { _, _ in
                runtime.applyPowerProfile(profile)
            }
        }
    }

    static func registerPluginActions(runtime: KeystivoRuntime) {
        registry.unregister(prefix: "plugin.")
        let language = Localizer.shared.languageCode
        for (plugin, command) in PluginManager.shared.enabledCommands {
            let id = "plugin.\(plugin.id).\(command.id)"
            register(id, command.icon ?? plugin.manifest.icon ?? "puzzlepiece.extension", .plugins,
                     parameters: command.acceptsQuery == true ? [ParameterSpec("query", "param.query", .text, optional: true)] : [],
                     keywords: (command.keywords ?? []) + [plugin.manifest.localizedName(for: language)],
                     titleKey: plugin.title(of: command, language: language)) { arguments, _ in
                let output = try await PluginManager.shared.run(command, of: plugin, query: arguments.string("query") ?? "")
                switch output {
                case .done(let message):
                    runtime.hud.show(symbol: "checkmark.circle", text: message ?? plugin.title(of: command, language: language))
                case .text, .items:
                    runtime.launcher.show(pluginOutput: output, title: plugin.title(of: command, language: language))
                }
            }
        }
    }
}
