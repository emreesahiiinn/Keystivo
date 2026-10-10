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

/// The menu bar control center ("menü çubuğunda birleşik kontrol merkezi").
struct ControlCenterView: View {
    let runtime: KeystivoRuntime
    @State private var showsMixer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if PermissionCenter.shared.missingEssential { permissionBanner }
            profiles
            quickToggles
            Divider()
            if showsMixer {
                MixerView(runtime: runtime, compact: true)
            } else {
                audioSummary
            }
            Divider()
            windowGrid
            Divider()
            powerRow
            if !BrightnessController.shared.targets.isEmpty { brightnessRows }
            Divider()
            toolsRow
            Divider()
            commandGrid
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "command.square.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text("Keystivo").font(.headline)
                Text(runtime.profiles.active?.name ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { runtime.launcher.show(mode: .root) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help(L("action.launcher.show"))
            Button { runtime.windowsUI.showSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help(L("action.app.settings"))
        }
    }

    private var permissionBanner: some View {
        Button {
            runtime.windowsUI.showSettings(section: .diagnostics)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("cc.permissionTitle")).font(.caption.weight(.semibold))
                    Text(L("cc.permissionBody")).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Profiles

    private var profiles: some View {
        HStack(spacing: 6) {
            ForEach(runtime.config.workspace.profiles) { profile in
                let active = profile.id == runtime.config.workspace.activeProfileID
                Button { runtime.profiles.activate(profile.id) } label: {
                    Label(profile.name, systemImage: profile.symbolName)
                        .font(.caption.weight(active ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.color(named: profile.colorName).opacity(0.25) : Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Toggles

    private var quickToggles: some View {
        let focus = FocusController.shared
        let keepAwake = KeepAwakeController.shared
        let clipboard = ClipboardMonitor.shared
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ToggleTile(symbol: "moon.fill", title: L("cc.focus"), isOn: focus.isActive, color: .indigo) { focus.toggle() }
            ToggleTile(symbol: "cup.and.saucer.fill", title: L("cc.keepAwake"), isOn: keepAwake.mode != .off, color: .brown) { keepAwake.toggle() }
            ToggleTile(symbol: AudioDeviceManager.shared.inputMuted ? "mic.slash.fill" : "mic.fill", title: L("cc.mic"), isOn: !AudioDeviceManager.shared.inputMuted, color: .red) {
                AudioDeviceManager.shared.toggleInputMute()
            }
            ToggleTile(symbol: "clipboard.fill", title: L("cc.clipboard"), isOn: !clipboard.isPaused, color: .orange) { clipboard.setPaused(!clipboard.isPaused) }
            ToggleTile(symbol: "hand.draw.fill", title: L("cc.gestures"), isOn: runtime.config.gestures.trackpadEnabled || runtime.config.gestures.mouseEnabled, color: .mint) {
                let enable = !(runtime.config.gestures.trackpadEnabled || runtime.config.gestures.mouseEnabled)
                runtime.config.gestures.trackpadEnabled = enable
                runtime.config.gestures.mouseEnabled = enable
            }
            ToggleTile(symbol: "bolt.fill", title: L("cc.automation"), isOn: runtime.config.automation.isEnabled, color: .yellow) { runtime.config.automation.isEnabled.toggle() }
            ToggleTile(symbol: "dock.rectangle", title: L("cc.launcherBar"), isOn: runtime.config.dock.launcherBar.isEnabled, color: .blue) { runtime.config.dock.launcherBar.isEnabled.toggle() }
            ToggleTile(symbol: "text.badge.plus", title: L("cc.snippets"), isOn: runtime.config.snippets.expansionEnabled, color: .teal) { runtime.config.snippets.expansionEnabled.toggle() }
        }
    }

    // MARK: Audio

    private var audioSummary: some View {
        let devices = AudioDeviceManager.shared
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: devices.defaultOutput?.symbolName ?? "speaker.wave.2")
                Text(devices.defaultOutput?.name ?? "—").font(.caption).lineLimit(1)
                Spacer()
                Button(L("cc.mixer")) { withAnimation(.snappy) { showsMixer = true } }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Slider(value: Binding(get: { Double(devices.outputVolume) }, set: { devices.setOutputVolume(Float($0)) }), in: 0...1)
                .controlSize(.small)
        }
    }

    // MARK: Windows

    private var windowGrid: some View {
        let positions: [SnapPosition] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .center, .firstThird, .lastThird]
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("category.windows")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(positions) { position in
                    Button {
                        snapPreviousApp(position)
                    } label: {
                        Image(systemName: position.symbolName)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(L(position.titleKey))
                }
            }
        }
    }

    /// The menu bar window is key while open; act on the app that was frontmost.
    private func snapPreviousApp(_ position: SnapPosition) {
        NSApp.keyWindow?.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            ActionRegistry.shared.run(ActionInvocation("windows.snap.\(position.rawValue)"), source: .menuBar)
        }
    }

    // MARK: Power

    private var powerRow: some View {
        let power = PowerMonitor.shared
        return HStack(spacing: 8) {
            Image(systemName: power.symbolName)
            if let level = power.batteryLevel {
                Text("\(level)%").font(.caption.monospacedDigit())
                if let minutes = power.minutesRemaining {
                    Text(L(power.isOnAC ? "cc.untilFull" : "cc.remaining", minutes / 60, minutes % 60))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(L("cc.onPower")).font(.caption)
            }
            if power.isLowPowerMode { Badge(text: L("cc.lowPower"), color: .yellow) }
            if power.hasBattery, runtime.config.system.chargeLimit.isEnabled {
                Button { runtime.windowsUI.showSettings(section: .battery) } label: {
                    Badge(text: runtime.chargeLimiter.isToppingUp ? L("cc.toppingUp") : L("cc.limit", runtime.config.system.chargeLimit.limit), color: .green)
                }
                .buttonStyle(.plain)
                .help(L("settings.page.battery"))
            }
            Spacer()
            Menu {
                ForEach(runtime.config.system.powerProfiles) { profile in
                    Button { runtime.applyPowerProfile(profile) } label: {
                        Label(profile.name, systemImage: runtime.config.system.activePowerProfileID == profile.id ? "checkmark" : profile.symbolName)
                    }
                }
            } label: {
                Text(runtime.config.system.powerProfiles.first { $0.id == runtime.config.system.activePowerProfileID }?.name ?? L("cc.powerProfile"))
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Brightness

    private var brightnessRows: some View {
        let controller = BrightnessController.shared
        return VStack(spacing: 4) {
            ForEach(controller.targets) { target in
                HStack(spacing: 8) {
                    Image(systemName: target.brightness < 0.5 ? "sun.min" : "sun.max")
                        .frame(width: 16)
                        .contentTransition(.symbolEffect(.replace))
                    Slider(value: Binding(get: { target.brightness }, set: { controller.setBrightness($0, for: target.id) }), in: 0...1)
                        .controlSize(.small)
                    if controller.targets.count > 1 {
                        Text(target.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 74, alignment: .leading)
                    }
                }
                .help(target.name)
            }
        }
    }

    // MARK: Tools

    private var toolsRow: some View {
        let tools: [(String, String, String)] = [
            ("tools.captureText", "text.viewfinder", "cc.tool.ocr"),
            ("tools.annotate", "pencil.tip.crop.circle", "cc.tool.annotate"),
            ("tools.recordScreen", ScreenRecorder.shared.isActive ? "stop.circle.fill" : "record.circle", "cc.tool.record"),
            ("tools.pickColor", "eyedropper", "cc.tool.color"),
            ("files.toggleShelf", "tray.full", "cc.tool.shelf"),
            ("files.uninstallApp", "trash.square", "cc.tool.uninstall"),
        ]
        return HStack(spacing: 6) {
            ForEach(tools, id: \.0) { id, symbol, title in
                Button {
                    NSApp.keyWindow?.close()
                    ActionRegistry.shared.run(ActionInvocation(id), source: .menuBar)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: symbol).font(.system(size: 14))
                        Text(L(title)).font(.system(size: 9)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .keystivoTileBackground(isOn: false, color: .accentColor, cornerRadius: 8)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Commands

    private var commandGrid: some View {
        let commands: [SystemCommand] = [.lockScreen, .sleepDisplays, .toggleDarkMode, .showDesktop, .screenSaver, .ejectAll, .toggleHiddenFiles, .emptyTrash]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(commands) { command in
                Button {
                    NSApp.keyWindow?.close()
                    ActionRegistry.shared.run(ActionInvocation("system.\(command.rawValue)"), source: .menuBar)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: command.symbolName).font(.system(size: 14))
                        Text(L(command.titleKey)).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(L("action.clipboard.history")) {
                NSApp.keyWindow?.close()
                runtime.launcher.show(mode: .clipboard)
            }
            .buttonStyle(.borderless)
            Spacer()
            Button(L("menu.quit")) { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.caption)
    }
}

private struct ToggleTile: View {
    let symbol: String
    let title: String
    let isOn: Bool
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? .white : .secondary)
                    .symbolEffect(.bounce, value: isOn)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(isOn ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.primary.opacity(0.08))))
                    .shadow(color: isOn ? color.opacity(0.45) : .clear, radius: 6, y: 2)
                    .scaleEffect(hovering ? 1.08 : 1)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
                    .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isOn)
                Text(title)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
