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

// MARK: - Hotkeys

/// Registers user shortcuts with the system. App-scoped bindings are only
/// registered while their app is frontmost, so they never block other apps.
@Observable
final class HotkeyService {
    private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private var tokens: [UUID: HotKeyToken] = [:]
    @ObservationIgnored private var tapTokens: [UUID] = []
    @ObservationIgnored private var bindings: [HotkeyBinding] = []
    @ObservationIgnored private var profileID: UUID?
    @ObservationIgnored private var frontmost: String?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init() {
        frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frontmost = bundleID
                if self.bindings.contains(where: { !$0.appBundleIDs.isEmpty }) { self.register() }
            }
        }
    }

    func update(bindings: [HotkeyBinding], profileID: UUID?) {
        self.bindings = bindings
        self.profileID = profileID
        register()
    }

    /// Bindings active right now (profile + frontmost app), app-specific first.
    var effectiveBindings: [HotkeyBinding] {
        let active = bindings.filter { binding in
            binding.isEnabled && binding.combo != nil
                && (binding.profileIDs.isEmpty || profileID.map(binding.profileIDs.contains) == true)
        }
        var result: [HotkeyBinding] = []
        var claimed = Set<KeyCombo>()
        for binding in active where !binding.appBundleIDs.isEmpty {
            guard let frontmost, binding.appBundleIDs.contains(frontmost), let combo = binding.combo else { continue }
            if claimed.insert(combo).inserted { result.append(binding) }
        }
        for binding in active where binding.appBundleIDs.isEmpty {
            guard let combo = binding.combo, claimed.insert(combo).inserted else { continue }
            result.append(binding)
        }
        return result
    }

    private func register() {
        for token in tokens.values { HotKeyCenter.shared.unregister(token) }
        tokens.removeAll()
        for id in tapTokens { TapHotKeys.shared.unregister(id) }
        tapTokens.removeAll()
        var newFailures: [UUID: String] = [:]
        for binding in effectiveBindings {
            guard let combo = binding.combo else { continue }
            let actions = binding.actions
            let fire: @MainActor () -> Void = {
                let context = ActionContext(source: .hotkey, variables: ["hotkeyModifiers": String(combo.modifiers.rawValue)])
                Task { try? await ActionRegistry.shared.perform(chain: actions, context: context) }
            }
            // Chords macOS consumes itself (⌘⇥, ⌘`) go straight to the event tap.
            if TapHotKeys.systemReservedCombos.contains(combo) {
                tapTokens.append(TapHotKeys.shared.register(combo, handler: fire))
                if !AXIsProcessTrusted() { newFailures[binding.id] = L("hotkey.error.needsAccessibility") }
                continue
            }
            do {
                tokens[binding.id] = try HotKeyCenter.shared.register(combo, onPress: fire)
            } catch {
                // Taken by another app or rejected by Carbon: fall back to the event tap.
                if AXIsProcessTrusted() {
                    tapTokens.append(TapHotKeys.shared.register(combo, handler: fire))
                } else {
                    newFailures[binding.id] = error.localizedDescription
                }
            }
        }
        if newFailures != failures { failures = newFailures }
    }

    /// Re-registers everything (e.g. after Accessibility was granted).
    func reregister() { register() }

    func suspend(_ suspended: Bool) { HotKeyCenter.shared.isSuspended = suspended }
}

// MARK: - Gestures

/// Routes recognized trackpad/mouse gestures to bindings, honoring app-specific
/// profiles. While recording in Settings, gestures go to the recorder instead.
@Observable
final class GestureService {
    private(set) var lastTrigger: GestureTrigger?
    @ObservationIgnored var recorder: ((GestureTrigger) -> Void)?
    @ObservationIgnored private var settings = GestureSettings()
    @ObservationIgnored private var profileID: UUID?

    init() {
        TrackpadGestureEngine.shared.onGesture = { [weak self] gesture in self?.received(.trackpad(gesture)) }
        MouseGestureEngine.shared.onGesture = { [weak self] gesture in self?.received(.mouse(gesture)) }
        EventTapManager.shared.add(MouseGestureEngine.shared)
    }

    func update(settings: GestureSettings, profileID: UUID?) {
        self.settings = settings
        self.profileID = profileID
        let hasTrackpadBindings = settings.bindings.contains { binding in
            if case .trackpad = binding.trigger { return binding.isEnabled }
            return false
        }
        TrackpadGestureEngine.shared.setRunning((settings.trackpadEnabled && hasTrackpadBindings) || recorder != nil)
        let mouse = MouseGestureEngine.shared
        if mouse.button != settings.mouseButton { mouse.button = settings.mouseButton }
        let mouseEnabled = settings.mouseEnabled || recorder != nil
        if mouse.isEnabled != mouseEnabled { mouse.isEnabled = mouseEnabled }
        mouse.excludedBundleIDs = Set(settings.mouseExcludedApps)
    }

    func startRecording(_ handler: @escaping (GestureTrigger) -> Void) {
        recorder = handler
        update(settings: settings, profileID: profileID)
    }

    func stopRecording() {
        recorder = nil
        update(settings: settings, profileID: profileID)
    }

    private func received(_ trigger: GestureTrigger) {
        lastTrigger = trigger
        if let recorder {
            recorder(trigger)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let binding = GestureResolver.resolve(trigger, in: settings.bindings, frontmostBundleID: frontmost, profileID: profileID) else { return }
        ActionRegistry.shared.run(chain: binding.actions, source: .gesture)
    }
}

// MARK: - Profiles

/// Switches user/workspace profiles and applies their side effects.
@Observable
final class ProfileService {
    @ObservationIgnored private unowned let runtime: KeystivoRuntime

    init(runtime: KeystivoRuntime) { self.runtime = runtime }

    var profiles: [UserProfile] { runtime.config.workspace.profiles }
    var active: UserProfile? { profiles.first { $0.id == runtime.config.workspace.activeProfileID } }

    func activate(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        runtime.config.workspace.activeProfileID = id
        apply(profile)
        runtime.hud.show(symbol: profile.symbolName, text: L("profile.activated", profile.name))
        AutomationEngine.shared.handle(.profileActivated(id))
    }

    func activateNext() {
        guard !profiles.isEmpty else { return }
        let index = profiles.firstIndex { $0.id == active?.id } ?? -1
        activate(profiles[(index + 1) % profiles.count].id)
    }

    private func apply(_ profile: UserProfile) {
        let config = runtime.config
        if let audioID = profile.audioProfileID, let audio = config.audio.profiles.first(where: { $0.id == audioID }) {
            AudioProfileApplier.apply(audio)
        }
        if let powerID = profile.powerProfileID, let power = config.system.powerProfiles.first(where: { $0.id == powerID }) {
            runtime.applyPowerProfile(power)
        }
        if let inputSource = profile.inputSourceID { InputSourceManager.shared.select(id: inputSource) }
        for bundleID in profile.quitApps {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        }
        for bundleID in profile.hideApps {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.hide() }
        }
        Task {
            for bundleID in profile.launchApps where NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                }
            }
            if let layoutID = profile.layoutID, let layout = config.windows.layouts.first(where: { $0.id == layoutID }) {
                if !profile.launchApps.isEmpty { try? await Task.sleep(for: .seconds(1.5)) }
                await LayoutManager.shared.restore(layout)
            }
            if profile.startsFocus { FocusController.shared.start() }
            if !profile.activationActions.isEmpty {
                try? await ActionRegistry.shared.perform(chain: profile.activationActions, context: ActionContext(source: .automation))
            }
        }
    }
}

// MARK: - Automation environment

/// Live implementation of the condition environment.
final class LiveAutomationEnvironment: AutomationEnvironment {
    unowned let runtime: KeystivoRuntime
    init(runtime: KeystivoRuntime) { self.runtime = runtime }

    var now: Date { .now }
    var calendar: Calendar { .current }
    var frontmostBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    func isRunning(_ bundleID: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    var powerSource: PowerSourceKind { PowerMonitor.shared.isOnAC ? .ac : .battery }
    var batteryLevel: Int? { PowerMonitor.shared.batteryLevel }
    var displayCount: Int { NSScreen.screens.count }
    var activeProfileID: UUID? { runtime.config.workspace.activeProfileID }
    var audioOutputUID: String? { AudioDeviceManager.shared.defaultOutput?.uid }
    var connectedInputDeviceNames: [String] { InputDeviceMonitor.shared.devices.map(\.name) }
    var isFocusActive: Bool { FocusController.shared.isActive }
}
