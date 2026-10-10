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

/// Registers every built-in action with the shared ``ActionRegistry``.
enum BuiltinActions {
    static func registerAll(runtime: KeystivoRuntime) {
        registerWindowActions(runtime: runtime)
        registerAppActions(runtime: runtime)
        registerAudioActions(runtime: runtime)
        registerNavigationActions(runtime: runtime)
        registerClipboardActions(runtime: runtime)
        registerLauncherActions(runtime: runtime)
        registerWorkspaceActions(runtime: runtime)
        registerSystemActions(runtime: runtime)
        registerAutomationActions(runtime: runtime)
        registerUtilityActions(runtime: runtime)
        registerChoiceProviders(runtime: runtime)
        registerDynamicActions(runtime: runtime)
        registerPluginActions(runtime: runtime)
    }

    static var registry: ActionRegistry { .shared }

    /// Throws a permission error (and prompts) when Accessibility is missing.
    static func requireAccessibility() throws(ActionError) {
        guard AXIsProcessTrusted() else { throw .permissionRequired(.accessibility) }
    }

    static func register(
        _ id: String, _ symbol: String, _ category: ActionCategory,
        parameters: [ParameterSpec] = [], keywords: [String] = [], confirm: Bool = false,
        launcher: Bool = true, titleKey: String? = nil,
        handler: @escaping ActionHandler
    ) {
        registry.register(ActionDescriptor(
            id: id, titleKey: titleKey ?? "action.\(id)", symbol: symbol, category: category,
            parameters: parameters, keywords: keywords, requiresConfirmation: confirm, showsInLauncher: launcher
        ), handler: handler)
    }

    // MARK: Choice providers for editors

    static func registerChoiceProviders(runtime: KeystivoRuntime) {
        registry.choiceProviders["audioOutputs"] = { AudioDeviceManager.shared.outputDevices.map { ChoiceOption($0.uid, $0.name) } }
        registry.choiceProviders["audioInputs"] = { AudioDeviceManager.shared.inputDevices.map { ChoiceOption($0.uid, $0.name) } }
        registry.choiceProviders["audioProfiles"] = { runtime.config.audio.profiles.map { ChoiceOption($0.id.uuidString, $0.name) } }
        registry.choiceProviders["layouts"] = { runtime.config.windows.layouts.map { ChoiceOption($0.id.uuidString, $0.name) } }
        registry.choiceProviders["workflows"] = { runtime.config.automation.workflows.map { ChoiceOption($0.id.uuidString, $0.name) } }
        registry.choiceProviders["profiles"] = { runtime.config.workspace.profiles.map { ChoiceOption($0.id.uuidString, $0.name) } }
        registry.choiceProviders["appGroups"] = { runtime.config.workspace.appGroups.map { ChoiceOption($0.id.uuidString, $0.name) } }
        registry.choiceProviders["powerProfiles"] = { runtime.config.system.powerProfiles.map { ChoiceOption($0.id, $0.name) } }
        registry.choiceProviders["inputSources"] = { InputSourceManager.shared.sources.map { ChoiceOption($0.id, $0.name) } }
        registry.choiceProviders["snippets"] = { runtime.config.snippets.snippets.map { ChoiceOption($0.id.uuidString, $0.name) } }
    }

    static func choice<T: RawRepresentable & CaseIterable>(_ type: T.Type, titleKey: (T) -> String) -> [ChoiceOption] where T.RawValue == String {
        T.allCases.map { ChoiceOption($0.rawValue, titleKey($0)) }
    }
}

// MARK: - Windows

extension BuiltinActions {
    static func registerWindowActions(runtime: KeystivoRuntime) {
        let windows = WindowManager.shared
        for position in SnapPosition.allCases {
            register("windows.snap.\(position.rawValue)", position.symbolName, .windows, keywords: ["snap", "window", "tile", position.rawValue], titleKey: position.titleKey) { _, _ in
                try requireAccessibility()
                try windows.snapFocused(position)
                runtime.hud.show(symbol: position.symbolName, text: L(position.titleKey))
            }
        }
        for target in DisplayTarget.allCases {
            register("windows.display.\(target.rawValue)", "display.2", .windows, keywords: ["monitor", "screen", "display", "move"], titleKey: "action.windows.display.\(target.rawValue)") { _, _ in
                try requireAccessibility()
                try windows.moveFocused(to: target)
            }
        }
        register("windows.restore", "arrow.uturn.backward.square", .windows, keywords: ["restore", "original"]) { _, _ in
            try requireAccessibility()
            try windows.restoreFocused()
        }
        register("windows.larger", "plus.magnifyingglass", .windows, keywords: ["resize", "grow"]) { _, _ in
            try requireAccessibility()
            try windows.resizeFocused(larger: true)
        }
        register("windows.smaller", "minus.magnifyingglass", .windows, keywords: ["resize", "shrink"]) { _, _ in
            try requireAccessibility()
            try windows.resizeFocused(larger: false)
        }
        for (direction, dx, dy) in [("up", 0.0, -40.0), ("down", 0.0, 40.0), ("left", -40.0, 0.0), ("right", 40.0, 0.0)] {
            register("windows.nudge.\(direction)", "arrow.\(direction).square", .windows, keywords: ["move", "nudge"]) { _, _ in
                try requireAccessibility()
                try windows.nudgeFocused(dx: dx, dy: dy)
            }
        }
        register("windows.minimize", "minus.square", .windows, keywords: ["minimize", "hide"]) { _, _ in
            try requireAccessibility()
            try windows.minimizeFocused()
        }
        register("windows.close", "xmark.square", .windows, keywords: ["close"]) { _, _ in
            try requireAccessibility()
            try windows.closeFocused()
        }
        register("windows.fullscreen", "arrow.up.left.and.arrow.down.right", .windows, keywords: ["full screen"]) { _, _ in
            try requireAccessibility()
            try windows.toggleFullScreenFocused()
        }
        register("windows.undo", "arrow.uturn.backward", .windows, keywords: ["undo", "revert"]) { _, _ in
            try requireAccessibility()
            windows.undoLastMove()
        }
        register("windows.switcher", "rectangle.on.rectangle", .windows, keywords: ["switch", "alt tab", "cmd tab", "windows"]) { _, context in
            try requireAccessibility()
            let modifiers = context.variables["hotkeyModifiers"].flatMap(Int.init).map(KeyModifiers.init(rawValue:)) ?? []
            await runtime.switcher.toggle(scope: .all, holdModifiers: modifiers)
        }
        register("windows.switcherApp", "rectangle.stack", .windows, keywords: ["same app", "windows"]) { _, context in
            try requireAccessibility()
            let modifiers = context.variables["hotkeyModifiers"].flatMap(Int.init).map(KeyModifiers.init(rawValue:)) ?? []
            await runtime.switcher.toggle(scope: .frontmostApp, holdModifiers: modifiers)
        }
        register("windows.previous", "arrow.left.arrow.right.square", .windows, keywords: ["last", "previous", "back"]) { _, _ in
            try requireAccessibility()
            guard let record = FocusHistory.shared.previousWindow() else { return }
            WindowFocus.focus(window: AXElement.application(pid: record.pid).windows.first { $0.windowID == record.windowID } ?? AXElement.application(pid: record.pid), windowID: record.windowID, pid: record.pid)
        }
        for style in ArrangementStyle.allCases {
            register("windows.arrange.\(style.rawValue)", "rectangle.split.3x3", .windows, keywords: ["tile", "arrange", "stack", style.rawValue], titleKey: style.titleKey) { _, _ in
                try requireAccessibility()
                await WindowArranger.arrange(style, scope: .currentScreen, gap: runtime.config.windows.gap)
            }
        }
        register("windows.arrange", "rectangle.split.3x3", .windows, parameters: [
            ParameterSpec("style", "param.style", .choice(choice(ArrangementStyle.self) { $0.titleKey }), default: .string(ArrangementStyle.grid.rawValue)),
            ParameterSpec("scope", "param.scope", .choice(choice(ArrangementScope.self) { $0.titleKey }), default: .string(ArrangementScope.currentScreen.rawValue)),
        ], launcher: false) { arguments, _ in
            try requireAccessibility()
            let style = ArrangementStyle(rawValue: arguments.string("style") ?? "") ?? .grid
            let scope = ArrangementScope(rawValue: arguments.string("scope") ?? "") ?? .currentScreen
            await WindowArranger.arrange(style, scope: scope, gap: runtime.config.windows.gap)
        }
        register("windows.gatherToScreen", "rectangle.compress.vertical", .windows, keywords: ["gather", "collect", "monitor"]) { _, _ in
            try requireAccessibility()
            await WindowArranger.gatherToCurrentScreen()
        }
        register("windows.saveLayout", "square.and.arrow.down.on.square", .workspace, parameters: [
            ParameterSpec("name", "param.name", .text, optional: true),
        ], keywords: ["layout", "save", "arrangement"]) { arguments, _ in
            try requireAccessibility()
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.locale = Localizer.shared.locale
            let name = arguments.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? L("layout.defaultName", formatter.string(from: .now))
            let layout = await LayoutManager.shared.capture(name: name)
            LayoutManager.shared.save(layout)
            runtime.hud.show(symbol: "square.and.arrow.down.on.square", text: L("layout.saved", name))
        }
        register("windows.restoreLayout", "square.and.arrow.up.on.square", .workspace, parameters: [
            ParameterSpec("layout", "param.layout", .dynamicChoice("layouts")),
        ], launcher: false) { arguments, _ in
            try requireAccessibility()
            guard let id = arguments.string("layout").flatMap(UUID.init), let layout = runtime.config.windows.layouts.first(where: { $0.id == id }) else {
                throw ActionError.notAvailable(L("layout.error.missing"))
            }
            let count = await LayoutManager.shared.restore(layout)
            runtime.hud.show(symbol: "square.and.arrow.up.on.square", text: L("layout.restored", layout.name, count))
        }
        register("windows.applyDefaultPosition", "pin", .windows, keywords: ["default", "remember", "position"]) { _, _ in
            try requireAccessibility()
            guard let rule = DefaultPositionService.shared.ruleFromFocusedWindow() else { return }
            runtime.config.windows.rules.removeAll { $0.bundleID == rule.bundleID }
            runtime.config.windows.rules.append(rule)
            runtime.hud.show(symbol: "pin", text: L("windows.rule.saved", AppDisplayName.name(forBundleID: rule.bundleID) ?? rule.bundleID))
        }
    }
}

// MARK: - Applications & groups

extension BuiltinActions {
    static func registerAppActions(runtime: KeystivoRuntime) {
        let appParameter = ParameterSpec("bundleID", "param.app", .application)
        register("apps.launch", "app.badge", .apps, parameters: [appParameter], launcher: false) { arguments, _ in
            try await AppControl.launch(bundleID: try arguments.require("bundleID"))
        }
        register("apps.toggle", "app.connected.to.app.below.fill", .apps, parameters: [appParameter], launcher: false) { arguments, _ in
            try await AppControl.toggle(bundleID: try arguments.require("bundleID"))
        }
        register("apps.quit", "xmark.circle", .apps, parameters: [appParameter], launcher: false) { arguments, _ in
            NSRunningApplication.runningApplications(withBundleIdentifier: try arguments.require("bundleID")).forEach { $0.terminate() }
        }
        register("apps.hide", "eye.slash", .apps, parameters: [appParameter], launcher: false) { arguments, _ in
            NSRunningApplication.runningApplications(withBundleIdentifier: try arguments.require("bundleID")).forEach { $0.hide() }
        }
        register("apps.quitFrontmost", "xmark.app", .apps, keywords: ["quit", "close app"]) { _, _ in
            NSWorkspace.shared.frontmostApplication?.terminate()
        }
        register("apps.forceQuitFrontmost", "exclamationmark.octagon", .apps, keywords: ["kill", "force quit"], confirm: true) { _, _ in
            NSWorkspace.shared.frontmostApplication?.forceTerminate()
        }
        register("apps.hideOthers", "eye.slash.circle", .apps, keywords: ["hide others", "declutter"]) { _, _ in
            NSWorkspace.shared.hideOtherApplications()
        }
        register("apps.showAll", "eye", .apps, keywords: ["unhide", "show all"]) { _, _ in
            NSWorkspace.shared.runningApplications.filter(\.isHidden).forEach { $0.unhide() }
        }
        register("apps.openURL", "safari", .apps, parameters: [ParameterSpec("url", "param.url", .url)], launcher: false) { arguments, _ in
            guard let url = URL(string: try arguments.require("url")) else { throw ActionError.failed(L("action.error.invalidURL")) }
            NSWorkspace.shared.open(url)
        }
        register("apps.openFile", "doc", .apps, parameters: [ParameterSpec("path", "param.path", .filePath)], launcher: false) { arguments, _ in
            let path = (try arguments.require("path") as NSString).expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        let groupParameter = ParameterSpec("group", "param.group", .dynamicChoice("appGroups"))
        register("apps.group.launch", "square.stack.3d.up", .apps, parameters: [groupParameter], launcher: false) { arguments, _ in
            for bundleID in try group(arguments, runtime).bundleIDs { try? await AppControl.launch(bundleID: bundleID, activate: false) }
        }
        register("apps.group.focus", "square.stack.3d.up.fill", .apps, parameters: [groupParameter], launcher: false) { arguments, _ in
            let group = try group(arguments, runtime)
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                if let id = app.bundleIdentifier, group.bundleIDs.contains(id) { app.unhide() } else { app.hide() }
            }
            if let first = group.bundleIDs.first { try? await AppControl.launch(bundleID: first) }
        }
        register("apps.group.hide", "square.stack.3d.down.forward", .apps, parameters: [groupParameter], launcher: false) { arguments, _ in
            for bundleID in try group(arguments, runtime).bundleIDs {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.hide() }
            }
        }
        register("apps.group.quit", "xmark.rectangle.portrait", .apps, parameters: [groupParameter], launcher: false) { arguments, _ in
            for bundleID in try group(arguments, runtime).bundleIDs {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
            }
        }
    }

    static func group(_ arguments: ActionArguments, _ runtime: KeystivoRuntime) throws -> AppGroup {
        guard let id = arguments.string("group").flatMap(UUID.init), let group = runtime.config.workspace.appGroups.first(where: { $0.id == id }) else {
            throw ActionError.notAvailable(L("group.error.missing"))
        }
        return group
    }
}

/// Launch/activate/hide helpers shared by actions, launcher and launcher bar.
enum AppControl {
    static func launch(bundleID: String, activate: Bool = true) async throws {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if activate {
                running.unhide()
                WindowFocus.activate(pid: running.processIdentifier)
            }
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw ActionError.notAvailable(L("apps.error.notInstalled", bundleID))
        }
        try await open(url: url, activate: activate)
    }

    static func open(url: URL, activate: Bool = true) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Launch if not running, focus if in background, hide if frontmost.
    static func toggle(bundleID: String) async throws {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if running.isActive {
                running.hide()
            } else {
                running.unhide()
                WindowFocus.activate(pid: running.processIdentifier)
            }
        } else {
            try await launch(bundleID: bundleID)
        }
    }
}
