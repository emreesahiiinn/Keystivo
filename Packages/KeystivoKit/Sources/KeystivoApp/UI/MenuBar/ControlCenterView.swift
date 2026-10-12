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
import SwiftUI

/// The menu bar control center: a glass panel of quick toggles, sound,
/// display brightness, window layouts and quick actions. Its modules and their
/// order are chosen in Settings › Menu Bar.
struct ControlCenterView: View {
    let runtime: KeystivoRuntime
    @Environment(\.dismissPanel) private var dismiss
    @State private var showsApps = false
    @State private var darkModeOverride: Bool?

    private var settings: ControlCenterSettings { runtime.config.menuBar.controlCenter }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if PermissionCenter.shared.missingEssential { permissionBanner }
            ForEach(settings.modules) { module in
                moduleView(module)
            }
            footer
        }
        .padding(8)
        #if DEBUG
        // `-KSTestPanelResize YES`: expands and collapses the sound section a few times.
        .task {
            guard UserDefaults.standard.bool(forKey: "KSTestPanelResize") else { return }
            for step in 0..<7 {
                try? await Task.sleep(for: .milliseconds(700))
                withAnimation(.snappy(duration: 0.22)) { showsApps.toggle() }
                try? await Task.sleep(for: .milliseconds(400))
                let frame = NSApp.windows.first { $0 is MenuBarPanel }.map { "\(NSStringFromRect($0.frame)) visible=\($0.isVisible)" } ?? "none"
                Log.logger("Debug").notice("panel resize step \(step) expanded=\(showsApps) \(frame, privacy: .public)")
            }
        }
        #endif
    }

    @ViewBuilder
    private func moduleView(_ module: ControlCenterModule) -> some View {
        switch module {
        case .toggles: if !settings.toggles.isEmpty { toggles }
        case .widgets: if !runtime.config.widgets.panel.isEmpty { PanelWidgetGrid(runtime: runtime) }
        case .sound: sound
        case .displays: if !BrightnessController.shared.targets.isEmpty { displays }
        case .windows: windows
        case .actions: if !quickActions.isEmpty { actions }
        case .power: if PowerMonitor.shared.hasBattery || runtime.config.system.powerProfiles.count > 1 { power }
        }
    }

    /// Runs an action after the panel closes, so it acts on the app that was in front.
    private func run(_ actionID: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            ActionRegistry.shared.run(ActionInvocation(actionID), source: .menuBar)
        }
    }

    private func shortcut(for actionID: String) -> KeyCombo? {
        runtime.config.hotkeys.first { $0.isEnabled && $0.actions.count == 1 && $0.actions[0].actionID == actionID && $0.appBundleIDs.isEmpty }?.combo
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
            Text("Keystivo").font(.system(size: 13, weight: .semibold))
            if runtime.config.workspace.profiles.count > 1 {
                CCMenu(title: runtime.profiles.active?.name ?? "") {
                    ForEach(runtime.config.workspace.profiles) { profile in
                        Button { runtime.profiles.activate(profile.id) } label: {
                            Label(profile.name, systemImage: profile.id == runtime.config.workspace.activeProfileID ? "checkmark" : profile.symbolName)
                        }
                    }
                }
                .help(L("cc.profile"))
            }
            Spacer()
            CCHeaderButton(symbol: "magnifyingglass", help: L("action.launcher.show")) {
                dismiss()
                runtime.launcher.show(mode: .root)
            }
            CCHeaderButton(symbol: "slider.horizontal.3", help: L("cc.customize")) {
                dismiss()
                runtime.windowsUI.showSettings(section: .menuBar)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 3)
        .padding(.bottom, 1)
    }

    private var permissionBanner: some View {
        Button {
            dismiss()
            runtime.windowsUI.showSettings(section: .diagnostics)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("cc.permissionTitle")).font(.system(size: 11.5, weight: .semibold))
                    Text(L("cc.permissionBody")).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: CC.cardRadius, style: .continuous).fill(Color.orange.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Toggles

    private var toggles: some View {
        CCCard {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 10) {
                ForEach(settings.toggles) { toggle in
                    toggleView(toggle)
                }
            }
        }
    }

    private var isDarkMode: Bool {
        darkModeOverride ?? (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
    }

    @ViewBuilder
    private func toggleView(_ toggle: ControlCenterToggle) -> some View {
        let title = L(toggle.titleKey)
        switch toggle {
        case .focus:
            CCToggle(symbol: "moon.fill", title: title, isOn: FocusController.shared.isActive) { FocusController.shared.toggle() }
        case .keepAwake:
            let keepAwake = KeepAwakeController.shared
            CCToggle(symbol: "cup.and.saucer.fill", title: title, isOn: keepAwake.mode != .off) { keepAwake.toggle() }
        case .mic:
            let devices = AudioDeviceManager.shared
            CCToggle(symbol: devices.inputMuted ? "mic.slash.fill" : "mic.fill", title: title, isOn: !devices.inputMuted) { devices.toggleInputMute() }
        case .darkMode:
            CCToggle(symbol: "circle.lefthalf.filled", title: title, isOn: isDarkMode) {
                darkModeOverride = !isDarkMode
                ActionRegistry.shared.run(ActionInvocation("system.toggleDarkMode"), source: .menuBar)
            }
        case .clipboard:
            let clipboard = ClipboardMonitor.shared
            CCToggle(symbol: "list.clipboard.fill", title: title, isOn: !clipboard.isPaused) { clipboard.setPaused(!clipboard.isPaused) }
        case .snippets:
            CCToggle(symbol: "text.badge.plus", title: title, isOn: runtime.config.snippets.expansionEnabled) { runtime.config.snippets.expansionEnabled.toggle() }
        case .gestures:
            let isOn = runtime.config.gestures.trackpadEnabled || runtime.config.gestures.mouseEnabled
            CCToggle(symbol: "hand.draw.fill", title: title, isOn: isOn) {
                runtime.config.gestures.trackpadEnabled = !isOn
                runtime.config.gestures.mouseEnabled = !isOn
            }
        case .automation:
            CCToggle(symbol: "bolt.fill", title: title, isOn: runtime.config.automation.isEnabled) { runtime.config.automation.isEnabled.toggle() }
        case .launcherBar:
            CCToggle(symbol: "dock.rectangle", title: title, isOn: runtime.config.dock.launcherBar.isEnabled) { runtime.config.dock.launcherBar.isEnabled.toggle() }
        case .focusFollowsMouse:
            CCToggle(symbol: "cursorarrow.motionlines", title: title, isOn: runtime.config.windows.focusFollowsMouse.isEnabled) { runtime.config.windows.focusFollowsMouse.isEnabled.toggle() }
        case .dragSnap:
            CCToggle(symbol: "rectangle.split.2x1.fill", title: title, isOn: runtime.config.windows.dragSnap.isEnabled) { runtime.config.windows.dragSnap.isEnabled.toggle() }
        }
    }

    // MARK: Sound

    private var sound: some View {
        let devices = AudioDeviceManager.shared
        return CCCard(L("cc.module.sound")) {
            CCMenu(title: devices.defaultOutput?.name ?? "—") {
                ForEach(devices.outputDevices) { device in
                    Button { try? devices.setDefaultOutput(uid: device.uid) } label: {
                        Label(device.name, systemImage: device.uid == devices.defaultOutput?.uid ? "checkmark" : device.symbolName)
                    }
                }
            }
        } content: {
            HStack(spacing: 6) {
                CCSlider(value: Binding(get: { devices.outputMuted ? 0 : Double(devices.outputVolume) }, set: {
                    if devices.outputMuted { devices.toggleOutputMute() }
                    devices.setOutputVolume(Float($0))
                }), symbol: volumeSymbol(devices), label: L("cc.module.sound")) { devices.toggleOutputMute() }
                Button {
                    withAnimation(.snappy(duration: 0.22)) { showsApps.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsApps ? 180 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(showsApps ? 0.14 : 0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("cc.appVolumes"))
            }
            if showsApps {
                AppVolumeList(runtime: runtime, limit: 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func volumeSymbol(_ devices: AudioDeviceManager) -> String {
        if devices.outputMuted || devices.outputVolume == 0 { return "speaker.slash.fill" }
        return devices.outputVolume < 0.34 ? "speaker.wave.1.fill" : devices.outputVolume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    // MARK: Displays

    private var displays: some View {
        let controller = BrightnessController.shared
        return CCCard(L("cc.module.displays")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controller.targets) { target in
                    if controller.targets.count > 1 {
                        Text(target.name).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    CCSlider(value: Binding(get: { target.brightness }, set: { controller.setBrightness($0, for: target.id) }),
                             symbol: target.brightness < 0.5 ? "sun.min.fill" : "sun.max.fill", label: target.name)
                }
            }
        }
    }

    // MARK: Windows

    private var windows: some View {
        let positions: [SnapPosition] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .firstThird, .lastThird, .center, .maximize]
        return CCCard(L("cc.module.windows")) {
            HStack(spacing: 4) {
                ForEach(positions) { position in
                    CCIconButton(symbol: position.symbolName, help: L(position.titleKey)) { run("windows.snap.\(position.rawValue)") }
                }
            }
        }
    }

    // MARK: Quick actions

    private var quickActions: [ActionDescriptor] {
        settings.actions.compactMap { ActionRegistry.shared.descriptors[$0] }
    }

    private var actions: some View {
        CCCard(L("cc.module.actions")) {
            VStack(spacing: 0) {
                ForEach(quickActions) { descriptor in
                    CCRow(symbol: descriptor.symbolName, title: L(descriptor.titleKey), shortcut: shortcut(for: descriptor.id)) { run(descriptor.id) }
                }
            }
            .padding(.horizontal, -6)
            .padding(.bottom, -4)
        }
    }

    // MARK: Power

    private var power: some View {
        let power = PowerMonitor.shared
        return CCCard {
            HStack(spacing: 8) {
                Image(systemName: power.symbolName).font(.system(size: 13)).foregroundStyle(.secondary)
                if let level = power.batteryLevel {
                    Text("\(level)%").font(.system(size: 12, weight: .medium).monospacedDigit())
                    if let minutes = power.minutesRemaining {
                        Text(L(power.isOnAC ? "cc.untilFull" : "cc.remaining", minutes / 60, minutes % 60))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("cc.onPower")).font(.system(size: 12))
                }
                if power.isLowPowerMode { Badge(text: L("cc.lowPower"), color: .yellow) }
                if power.hasBattery, runtime.config.system.chargeLimit.isEnabled {
                    Badge(text: runtime.chargeLimiter.isToppingUp ? L("cc.toppingUp") : L("cc.limit", runtime.config.system.chargeLimit.limit), color: .green)
                }
                Spacer(minLength: 4)
                if runtime.config.system.powerProfiles.count > 1 {
                    CCMenu(title: runtime.config.system.powerProfiles.first { $0.id == runtime.config.system.activePowerProfileID }?.name ?? L("cc.powerProfile")) {
                        ForEach(runtime.config.system.powerProfiles) { profile in
                            Button { runtime.applyPowerProfile(profile) } label: {
                                Label(profile.name, systemImage: runtime.config.system.activePowerProfileID == profile.id ? "checkmark" : profile.symbolName)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 6).padding(.bottom, 4)
            CCRow(symbol: "list.clipboard", title: L("action.clipboard.history"), shortcut: shortcut(for: "clipboard.history")) {
                dismiss()
                runtime.launcher.show(mode: .clipboard)
            }
            CCRow(symbol: "gearshape", title: L("cc.settings"), shortcut: KeyCombo(kVK_ANSI_Comma, .command)) {
                dismiss()
                runtime.windowsUI.showSettingsAtLastSection()
            }
            CCRow(symbol: "power", title: L("menu.quit"), shortcut: KeyCombo(kVK_ANSI_Q, .command)) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// Widgets placed in the panel: small ones two to a row, others full width.
private struct PanelWidgetGrid: View {
    let runtime: KeystivoRuntime
    private let width: CGFloat = 316
    private let spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { instance in
                        WidgetView(runtime: runtime, instance: instance)
                            .padding(12)
                            .frame(width: cellSize(instance).width, height: cellSize(instance).height)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.055)))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                            .contextMenu { WidgetMenu(runtime: runtime, instance: instance) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var rows: [[WidgetInstance]] {
        var rows: [[WidgetInstance]] = []
        for instance in runtime.config.widgets.panel {
            if instance.size == .small, let last = rows.last, last.count == 1, last[0].size == .small {
                rows[rows.count - 1].append(instance)
            } else {
                rows.append([instance])
            }
        }
        return rows
    }

    private func cellSize(_ instance: WidgetInstance) -> CGSize {
        switch instance.size {
        case .small: CGSize(width: (width - spacing) / 2, height: (width - spacing) / 2)
        case .medium: CGSize(width: width, height: 150)
        case .large: CGSize(width: width, height: width)
        }
    }
}

/// Per-app volume rows for menu bar panels.
struct AppVolumeList: View {
    let runtime: KeystivoRuntime
    var limit = 12

    var body: some View {
        let apps = AppAudioController.shared
        VStack(alignment: .leading, spacing: 8) {
            if !runtime.config.audio.appVolumeEnabled {
                HStack {
                    Text(L("cc.appVolumeOff")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("cc.turnOn")) { runtime.config.audio.appVolumeEnabled = true }
                        .controlSize(.small)
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let audible = apps.audibleEntries(at: context.date)
                    if audible.isEmpty {
                        Text(L("mixer.empty")).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(audible.prefix(limit)) { entry in
                                AppVolumeRow(entry: entry)
                            }
                        }
                        .animation(.snappy(duration: 0.25), value: audible.map(\.id))
                    }
                }
            }
            if apps.lastError != nil {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L("mixer.error")).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(L("permissions.grant")) { PermissionCenter.shared.request(.audioCapture) }.controlSize(.small)
                }
            }
        }
        .padding(.top, 2)
    }
}

/// One app: icon, name, level and a wide slider; the menu picks its output device.
private struct AppVolumeRow: View {
    let entry: AppAudioEntry

    var body: some View {
        let apps = AppAudioController.shared
        let setting = apps.setting(for: entry.bundleID)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AppIconView(bundleID: entry.bundleID, size: 16)
                    .opacity(entry.isPlaying ? 1 : 0.55)
                Text(entry.name).font(.system(size: 11.5)).lineLimit(1)
                if entry.isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }
                Spacer(minLength: 4)
                Text(setting.muted ? L("mixer.muted") : "\(Int(setting.volume * 100))%")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    Button {
                        apps.setOutputDevice(nil, for: entry.bundleID)
                    } label: {
                        if setting.outputDeviceUID == nil { Label(L("mixer.systemOutput"), systemImage: "checkmark") } else { Text(L("mixer.systemOutput")) }
                    }
                    Divider()
                    ForEach(AudioDeviceManager.shared.outputDevices) { device in
                        Button {
                            apps.setOutputDevice(device.uid, for: entry.bundleID)
                        } label: {
                            if setting.outputDeviceUID == device.uid { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                        }
                    }
                } label: {
                    Image(systemName: setting.outputDeviceUID == nil ? "hifispeaker" : "hifispeaker.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(setting.outputDeviceUID == nil ? Color.secondary : Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("mixer.outputHelp"))
            }
            CCSlider(value: Binding(get: { setting.muted ? 0 : Double(setting.volume) }, set: {
                if setting.muted { apps.toggleMute(for: entry.bundleID) }
                apps.setVolume(Float($0), for: entry.bundleID)
            }), range: 0...1.5, symbol: setting.muted ? "speaker.slash.fill" : "speaker.fill", height: 16, label: entry.name) {
                apps.toggleMute(for: entry.bundleID)
            }
        }
    }
}

/// The sound mixer as its own menu bar panel (SoundSource-style).
struct MixerPanelView: View {
    let runtime: KeystivoRuntime
    @Environment(\.dismissPanel) private var dismiss

    var body: some View {
        let devices = AudioDeviceManager.shared
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("cc.mixerTitle")).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.top, 3)
            CCCard(L("audio.output")) {
                CCMenu(title: devices.defaultOutput?.name ?? "—") {
                    ForEach(devices.outputDevices) { device in
                        Button { try? devices.setDefaultOutput(uid: device.uid) } label: {
                            Label(device.name, systemImage: device.uid == devices.defaultOutput?.uid ? "checkmark" : device.symbolName)
                        }
                    }
                }
            } content: {
                CCSlider(value: Binding(get: { devices.outputMuted ? 0 : Double(devices.outputVolume) }, set: {
                    if devices.outputMuted { devices.toggleOutputMute() }
                    devices.setOutputVolume(Float($0))
                }), symbol: devices.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: L("audio.output")) { devices.toggleOutputMute() }
            }
            CCCard(L("audio.input")) {
                CCMenu(title: devices.defaultInput?.name ?? "—") {
                    ForEach(devices.inputDevices) { device in
                        Button { try? devices.setDefaultInput(uid: device.uid) } label: {
                            Label(device.name, systemImage: device.uid == devices.defaultInput?.uid ? "checkmark" : device.symbolName)
                        }
                    }
                }
            } content: {
                HStack(spacing: 8) {
                    Image(systemName: devices.inputMuted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(devices.inputMuted ? Color.red : Color.secondary)
                    Text(L(devices.inputMuted ? "audio.mic.muted" : "audio.mic.live")).font(.system(size: 12))
                    Spacer()
                    Toggle("", isOn: Binding(get: { !devices.inputMuted }, set: { _ in devices.toggleInputMute() }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
            CCCard(L("mixer.apps")) {
                if !AppAudioController.shared.settings.isEmpty {
                    Button(L("mixer.resetAll")) { AppAudioController.shared.resetAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            } content: {
                AppVolumeList(runtime: runtime)
            }
            Divider().padding(.horizontal, 6)
            CCRow(symbol: "gearshape", title: L("cc.soundSettings")) {
                dismiss()
                runtime.windowsUI.showSettings(section: .audio)
            }
        }
        .padding(8)
    }
}

/// Draws the mouse-gesture trail while a stroke is in progress.
final class MouseTrailController {
    private var windows: [OverlayWindow] = []
    private var isObserving = false

    func start(runtime: KeystivoRuntime) {
        guard !isObserving else { return }
        isObserving = true
        observe(runtime: runtime)
    }

    private func observe(runtime: KeystivoRuntime) {
        withObservationTracking {
            _ = MouseGestureEngine.shared.trail
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.update(trail: MouseGestureEngine.shared.trail, enabled: runtime.config.gestures.showsTrail)
                    self.observe(runtime: runtime)
                }
            }
        }
    }

    private func update(trail: [CGPoint]?, enabled: Bool) {
        guard enabled, let trail, trail.count > 1 else {
            windows.forEach { $0.orderOut(nil) }
            return
        }
        if windows.isEmpty {
            windows = NSScreen.screens.map { screen in
                let window = OverlayWindow(screen: screen)
                window.contentView = NSHostingView(rootView: MouseTrailView(screenFrame: ScreenGeometry.frameAX(of: screen)))
                return window
            }
        }
        windows.forEach { $0.orderFrontRegardless() }
    }
}


private struct MouseTrailView: View {
    let screenFrame: CGRect

    var body: some View {
        let engine = MouseGestureEngine.shared
        Canvas { context, _ in
            guard let trail = engine.trail, trail.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: trail[0].x - screenFrame.minX, y: trail[0].y - screenFrame.minY))
            for point in trail.dropFirst() {
                path.addLine(to: CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY))
            }
            context.stroke(path, with: .color(.accentColor.opacity(0.85)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .overlay(alignment: .top) {
            if !engine.currentStrokes.isEmpty {
                Text(MouseGesture(strokes: engine.currentStrokes).displayString)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .keystivoPanelBackground(cornerRadius: 10)
                    .padding(.top, 60)
            }
        }
        .allowsHitTesting(false)
    }
}
