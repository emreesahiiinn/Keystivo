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
import ServiceManagement

/// Composition root: owns the configuration and wires every module together.
///
/// Feature modules know nothing about each other; the runtime connects their
/// callbacks (e.g. power changes → automation events) and pushes configuration
/// into them whenever a section changes.
@Observable
public final class KeystivoRuntime {
    public static let shared = KeystivoRuntime()

    let store: ConfigurationStore
    let hotkeys = HotkeyService()
    let gestures = GestureService()
    @ObservationIgnored private(set) lazy var profiles = ProfileService(runtime: self)
    let hud = HUDController()
    @ObservationIgnored private(set) lazy var launcher = LauncherController(runtime: self)
    @ObservationIgnored private(set) lazy var switcher = SwitcherController(runtime: self)
    @ObservationIgnored private(set) lazy var hints = HintsController(runtime: self)
    @ObservationIgnored private(set) lazy var dockPreviews = DockPreviewController(runtime: self)
    @ObservationIgnored private(set) lazy var launcherBar = LauncherBarController(runtime: self)
    @ObservationIgnored private(set) lazy var mixer = MixerPanelController(runtime: self)
    @ObservationIgnored private(set) lazy var mouseTrail = MouseTrailController()
    @ObservationIgnored private(set) lazy var windowsUI = WindowPresenter(runtime: self)
    @ObservationIgnored private(set) lazy var automationEnvironment = LiveAutomationEnvironment(runtime: self)
    @ObservationIgnored private(set) lazy var dragSnapOverlay = DragSnapOverlay()
    @ObservationIgnored private(set) lazy var menuBarManager = MenuBarManager()
    @ObservationIgnored private(set) lazy var systemMonitorItem = SystemMonitorStatusItem()
    @ObservationIgnored private(set) lazy var shelf = ShelfController()
    @ObservationIgnored private(set) lazy var screenTools = ScreenToolsController(runtime: self)
    @ObservationIgnored private(set) lazy var linkRouting = LinkRoutingController(runtime: self)
    @ObservationIgnored private(set) lazy var presentation = PresentationOverlay()
    @ObservationIgnored private(set) lazy var annotationEditor = AnnotationEditorPresenter(runtime: self)
    @ObservationIgnored private(set) lazy var recording = RecordingController(runtime: self)
    let chargeLimiter = ChargeLimiter()
    @ObservationIgnored private var appliedKeyRemaps = false
    @ObservationIgnored private let systemEvents = SystemEventSource()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var applyingFromServices = false

    /// Shorthand for views and services; writes persist automatically.
    var config: KeystivoConfiguration {
        get { store.configuration }
        set { store.configuration = newValue }
    }

    public var isFirstLaunch: Bool { store.isFirstLaunch }

    init() {
        store = ConfigurationStore()
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        let config = store.configuration
        Localizer.shared.setPreference(config.general.language)
        applyActivationPolicy()
        applyAppearance()

        BuiltinActions.registerAll(runtime: self)
        wireModuleCallbacks()

        // Accessibility-dependent services (re)start when permission changes.
        PermissionCenter.shared.onChange = { [weak self] old, new in
            if old[.accessibility] != .granted, new[.accessibility] == .granted { self?.accessibilityGranted() }
        }

        WindowEventHub.shared.start()
        FocusHistory.shared.start()
        DefaultPositionService.shared.start()
        LayoutManager.shared.startMonitoringDisplays()
        AudioDeviceManager.shared.start()
        AppAudioController.shared.start()
        PowerMonitor.shared.start()
        InputSourceManager.shared.start()
        InputDeviceMonitor.shared.start()
        ClipboardMonitor.shared.settings = config.clipboard
        ClipboardMonitor.shared.start()
        EventTapManager.shared.add(SnippetExpander.shared)
        AppCatalog.shared.rescan()
        PluginManager.shared.reload()
        systemEvents.start()
        mouseTrail.start(runtime: self)
        DisplayManager.shared.start()
        chargeLimiter.settings = config.system.chargeLimit
        chargeLimiter.start()
        BrightnessController.shared.onAdjust = { [weak self] target in
            self?.hud.show(symbol: target.brightness < 0.5 ? "sun.min.fill" : "sun.max.fill", text: target.name, value: target.brightness)
        }
        BrightnessController.shared.start()
        EventTapManager.shared.add(BrightnessKeyHandler.shared)
        _ = linkRouting
        _ = dragSnapOverlay
        EventTapManager.shared.add(ScrollEngine.shared)
        EventTapManager.shared.add(MouseButtonEngine.shared)
        EventTapManager.shared.add(HyperKeyEngine.shared)
        MouseButtonEngine.shared.perform = { actions in ActionRegistry.shared.run(chain: actions, source: .gesture) }
        FolderRuleEngine.shared.onNotify = { rule, file in
            Task { await Notifier.post(title: rule, body: file) }
        }

        apply(old: nil, new: config)
        store.onChange = { [weak self] old, new in self?.apply(old: old, new: new) }

        AutomationEngine.shared.environment = automationEnvironment
        AutomationEngine.shared.handle(.keystivoLaunched)

        if !config.general.hasCompletedOnboarding {
            windowsUI.showOnboarding()
        }
        // Developer affordance: `open Keystivo.app --args -KSShowLauncherOnLaunch YES`.
        if UserDefaults.standard.bool(forKey: "KSShowLauncherOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.launcher.show(mode: .root) }
        }
        #if DEBUG
        // `--args -KSShowSettings displays` / `-KSAnnotateImage /path/to/image.png`
        if let page = UserDefaults.standard.string(forKey: "KSShowSettings"), let section = SettingsSection(rawValue: page) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.windowsUI.showSettings(section: section) }
        }
        if let path = UserDefaults.standard.string(forKey: "KSAnnotateImage"), let image = NSImage(contentsOfFile: path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.annotationEditor.open(image) }
        }
        // `-KSSnapshotWindows /dir`: renders our own windows to PNG (needs no screen-recording permission).
        if let directory = UserDefaults.standard.string(forKey: "KSSnapshotWindows") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = window.title.isEmpty ? "window-\(index)" : window.title.replacingOccurrences(of: "/", with: "-")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
                }
            }
        }
        #endif
        DiagnosticsCenter.shared.record(.info, module: "App", L("diagnostics.started", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
    }

    public func shutdown() {
        store.saveNow()
        if ScreenRecorder.shared.isActive {
            // Let the movie file finalize before quitting.
            ScreenRecorder.shared.stop()
            let deadline = Date.now.addingTimeInterval(3)
            while ScreenRecorder.shared.isActive, Date.now < deadline {
                RunLoop.main.run(until: .now.addingTimeInterval(0.05))
            }
        }
        chargeLimiter.shutdown()
        DisplayManager.shared.restoreAll()
        if appliedKeyRemaps {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await KeyRemapper.reset()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.5)
        }
        AppAudioController.shared.shutdown()
        FocusController.shared.stop(notify: false)
        KeepAwakeController.shared.set(.off)
    }

    private func accessibilityGranted() {
        WindowEventHub.shared.start()
        EventTapManager.shared.refresh()
        hotkeys.reregister()
        dockPreviews.setEnabled(config.dock.previewsEnabled)
        hud.show(symbol: "checkmark.shield", text: L("permission.granted", L(PermissionKind.accessibility.titleKey)))
    }

    // MARK: Module callbacks → runtime

    private func wireModuleCallbacks() {
        systemEvents.onEvent = { event in AutomationEngine.shared.handle(event) }

        AutomationEngine.shared.onChange = { [weak self] workflows in
            self?.writeBack { $0.automation.workflows = workflows }
        }
        LayoutManager.shared.onChange = { [weak self] layouts in
            self?.writeBack { $0.windows.layouts = layouts }
        }
        AppAudioController.shared.onSettingsChange = { [weak self] settings in
            self?.writeBack { $0.audio.appSettings = settings }
        }
        PluginManager.shared.onChange = { [weak self] in
            guard let self else { return }
            let plugins = PluginManager.shared
            self.writeBack {
                $0.plugins.trusted = plugins.trusted
                $0.plugins.disabled = plugins.disabled.sorted()
            }
            BuiltinActions.registerPluginActions(runtime: self)
        }
        AudioDeviceManager.shared.onDevicesChange = {
            AutomationEngine.shared.handle(.audioOutputChanged)
        }
        let previousOutputHandler = AudioDeviceManager.shared.onDefaultOutputChange
        AudioDeviceManager.shared.onDefaultOutputChange = { device in
            previousOutputHandler?(device)
            AutomationEngine.shared.handle(.audioOutputChanged)
        }
        PowerMonitor.shared.onChange = { [weak self] onAC, level, previous, sourceChanged in
            guard let self else { return }
            if sourceChanged {
                AutomationEngine.shared.handle(.powerSourceChanged(onAC ? .ac : .battery))
                if self.config.system.autoSwitchesPowerProfiles,
                   let profile = self.config.system.powerProfiles.first(where: { $0.autoApplyOn == (onAC ? "ac" : "battery") }) {
                    self.applyPowerProfile(profile)
                }
            }
            if let level, level != previous {
                AutomationEngine.shared.handle(.batteryLevel(level, previous: previous))
            }
            if sourceChanged || level != previous { self.chargeLimiter.evaluate() }
        }
        InputDeviceMonitor.shared.onConnect = { [weak self] device in
            AutomationEngine.shared.handle(.inputDeviceConnected(device.name))
            self?.applyDeviceProfiles(device, connected: true)
        }
        InputDeviceMonitor.shared.onDisconnect = { [weak self] device in
            AutomationEngine.shared.handle(.inputDeviceDisconnected(device.name))
            self?.applyDeviceProfiles(device, connected: false)
        }
        FocusController.shared.onStart = { AutomationEngine.shared.handle(.focusStarted) }
        FocusController.shared.onEnd = { AutomationEngine.shared.handle(.focusEnded) }

        WindowEventHub.shared.subscribe { event in
            switch event {
            case .windowFocused, .appActivated:
                FocusController.shared.focusedWindowChanged()
            default:
                break
            }
        }
        ActionRegistry.shared.onPerform = { [weak self] invocation, context, error in
            guard let self, let error, context.source != .workflow else { return }
            self.hud.show(symbol: "exclamationmark.triangle", text: error.localizedDescription, style: .warning)
            if case ActionError.permissionRequired(let kind) = error { PermissionCenter.shared.request(kind) }
            _ = invocation
        }
    }

    /// Writes service-originated state into the configuration without
    /// re-applying it to the service that produced it.
    private func writeBack(_ update: (inout KeystivoConfiguration) -> Void) {
        var copy = store.configuration
        update(&copy)
        guard copy != store.configuration else { return }
        applyingFromServices = true
        store.configuration = copy
        applyingFromServices = false
    }

    // MARK: Configuration → modules

    private func apply(old: KeystivoConfiguration?, new: KeystivoConfiguration) {
        func changed<T: Equatable>(_ keyPath: KeyPath<KeystivoConfiguration, T>) -> Bool {
            old.map { $0[keyPath: keyPath] != new[keyPath: keyPath] } ?? true
        }
        let profileChanged = changed(\.workspace.activeProfileID)

        if changed(\.general) {
            if Localizer.shared.preference != new.general.language { Localizer.shared.setPreference(new.general.language) }
            applyActivationPolicy()
            applyAppearance()
            applyLaunchAtLogin(new.general.launchAtLogin)
        }
        if changed(\.hotkeys) || profileChanged {
            hotkeys.update(bindings: new.hotkeys, profileID: new.workspace.activeProfileID)
        }
        if changed(\.windows) {
            let drag = DragSnapEngine.shared
            var zones = DragSnapZones.Configuration()
            zones.topEdgeMaximizes = new.windows.dragSnap.topEdgeMaximizes
            zones.bottomEdgeThirds = new.windows.dragSnap.bottomEdgeThirds
            drag.configuration = zones
            drag.bypassModifier = new.windows.dragSnap.commandBypasses ? .command : []
            drag.excludedBundleIDs = Set(new.windows.dragSnap.excludedApps)
            drag.gap = new.windows.gap
            if drag.isEnabled != new.windows.dragSnap.isEnabled { drag.isEnabled = new.windows.dragSnap.isEnabled }
            let manager = WindowManager.shared
            manager.gap = new.windows.gap
            manager.cyclesOnRepeat = new.windows.cyclesOnRepeat
            manager.preserveSnapAcrossDisplays = new.windows.preservesSnapAcrossDisplays
            if !applyingFromServices, LayoutManager.shared.layouts != new.windows.layouts {
                LayoutManager.shared.layouts = new.windows.layouts
            }
            DefaultPositionService.shared.rules = new.windows.rules
        }
        if changed(\.switcher) {
            switcher.settingsChanged()
        }
        if changed(\.dock) {
            dockPreviews.setEnabled(new.dock.previewsEnabled)
            launcherBar.apply(new.dock.launcherBar)
        }
        if changed(\.audio), !applyingFromServices {
            let apps = AppAudioController.shared
            if apps.settings != new.audio.appSettings { apps.settings = new.audio.appSettings }
            if apps.isEnabled != new.audio.appVolumeEnabled { apps.isEnabled = new.audio.appVolumeEnabled }
        }
        if changed(\.gestures) || profileChanged {
            gestures.update(settings: new.gestures, profileID: new.workspace.activeProfileID)
        }
        if (changed(\.automation) || profileChanged), !applyingFromServices {
            let engine = AutomationEngine.shared
            if engine.workflows != new.automation.workflows { engine.workflows = new.automation.workflows }
            if engine.isEnabled != new.automation.isEnabled { engine.isEnabled = new.automation.isEnabled }
            if engine.activeProfileID != new.workspace.activeProfileID { engine.activeProfileID = new.workspace.activeProfileID }
        }
        if changed(\.clipboard), ClipboardMonitor.shared.settings != new.clipboard {
            ClipboardMonitor.shared.settings = new.clipboard
        }
        if changed(\.snippets) {
            SnippetExpander.shared.snippets = new.snippets.snippets
            SnippetExpander.shared.isEnabled = new.snippets.expansionEnabled
            SnippetExpander.shared.excludedBundleIDs = Set(new.snippets.excludedApps)
        }
        if changed(\.workspace.focus) {
            FocusController.shared.settings = new.workspace.focus
        }
        if changed(\.system) {
            InputSourceManager.shared.appRules = new.system.inputSourceRules
            InputSourceManager.shared.remembersPerApp = new.system.remembersInputSourcePerApp
            if chargeLimiter.settings != new.system.chargeLimit { chargeLimiter.settings = new.system.chargeLimit }
        }
        if changed(\.plugins), !applyingFromServices {
            let plugins = PluginManager.shared
            if plugins.trusted != new.plugins.trusted { plugins.trusted = new.plugins.trusted }
            if plugins.disabled != Set(new.plugins.disabled) { plugins.disabled = Set(new.plugins.disabled) }
            BuiltinActions.registerPluginActions(runtime: self)
        }
        if changed(\.input) || changed(\.gestures) {
            if ScrollEngine.shared.settings != new.input.scroll { ScrollEngine.shared.settings = new.input.scroll }
            MouseButtonEngine.shared.bindings = new.input.mouseButtons
            MouseButtonEngine.shared.reservedButtons = new.gestures.mouseEnabled ? [new.gestures.mouseButton] : []
            if HyperKeyEngine.shared.settings != new.input.hyper { HyperKeyEngine.shared.settings = new.input.hyper }
        }
        if changed(\.input.hyper) || changed(\.input.remaps) {
            let remaps = new.input.remaps
            let hyper = new.input.hyper
            let needsMapping = hyper.isEnabled || remaps.contains(where: \.isEnabled)
            if needsMapping || appliedKeyRemaps {
                appliedKeyRemaps = needsMapping
                Task {
                    do {
                        if needsMapping { try await KeyRemapper.apply(remaps: remaps, hyper: hyper) } else { await KeyRemapper.reset() }
                    } catch {
                        DiagnosticsCenter.shared.record(error, module: "Input", context: L("hyper.error.apply"))
                    }
                }
            }
        }
        if changed(\.menuBar) {
            menuBarManager.apply(new.menuBar)
            systemMonitorItem.apply(new.menuBar)
        }
        if changed(\.files) {
            FolderRuleEngine.shared.rules = new.files.folderRules
            if FolderRuleEngine.shared.isEnabled != new.files.rulesEnabled { FolderRuleEngine.shared.isEnabled = new.files.rulesEnabled }
            shelf.apply(showOnDrag: new.files.shelfOnDrag)
        }
        if changed(\.presentation) {
            presentation.apply(new.presentation)
        }
        if changed(\.tools.brightnessKeysControlExternal) {
            BrightnessKeyHandler.shared.isEnabled = new.tools.brightnessKeysControlExternal
        }
        if changed(\.workspace.appGroups) || changed(\.workspace.profiles) || changed(\.audio.profiles) || changed(\.windows.layouts) {
            BuiltinActions.registerDynamicActions(runtime: self)
        }
    }

    // MARK: App-level settings

    func applyActivationPolicy() {
        let wantsDock = config.general.showsDockIcon || windowsUI.hasVisibleStandardWindow || annotationEditor.hasOpenWindows
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func applyAppearance() {
        switch config.general.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled { try service.register() }
            if !enabled, service.status == .enabled { try service.unregister() }
        } catch {
            DiagnosticsCenter.shared.record(error, module: "App", context: L("general.launchAtLogin"))
        }
    }

    func applyPowerProfile(_ profile: PowerProfile) {
        PowerProfileApplier.apply(profile)
        if profile.suspendsAppAudio { AppAudioController.shared.isEnabled = false } else {
            AppAudioController.shared.isEnabled = config.audio.appVolumeEnabled
        }
        ClipboardMonitor.shared.setPaused(profile.pausesClipboard)
        config.system.activePowerProfileID = profile.id
        hud.show(symbol: profile.symbolName, text: L("power.profile.applied", profile.name))
    }

    private func applyDeviceProfiles(_ device: InputDeviceInfo, connected: Bool) {
        for profile in config.system.deviceProfiles where profile.isEnabled && profile.matches(device) {
            if connected, let source = profile.inputSourceID { InputSourceManager.shared.select(id: source) }
            let actions = connected ? profile.onConnect : profile.onDisconnect
            if !actions.isEmpty { ActionRegistry.shared.run(chain: actions, source: .automation) }
        }
    }

    /// Records a launcher selection for frecency ranking.
    func recordUsage(_ id: String) {
        var stats = config.usage[id] ?? UsageStats()
        stats.count += 1
        stats.lastUsed = .now
        config.usage[id] = stats
    }
}

extension KeystivoRuntime {
    /// Imports shared `.keystivoflow` files opened from Finder (disabled until reviewed).
    func importWorkflows(from urls: [URL]) {
        var imported = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url), let workflows = try? AutomationLibrary.import(data) else { continue }
            config.automation.workflows.append(contentsOf: workflows)
            imported += workflows.count
        }
        guard imported > 0 else { return }
        hud.show(symbol: "bolt.badge.checkmark", text: L("automation.imported", imported))
        windowsUI.showSettings(section: .automation)
    }
}
