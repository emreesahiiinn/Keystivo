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
import ServiceManagement
import SwiftUI

// MARK: - Mouse & keyboard

struct MouseKeyboardPage: View {
    @Bindable var runtime: KeystivoRuntime

    var body: some View {
        Form {
            PageHeader(symbol: "computermouse.fill", color: .mint, titleKey: "settings.page.mouseKeyboard", subtitleKey: "mouseKeyboard.subtitle")
            Section {
                Toggle(L("mouseKeyboard.scrollEnabled"), isOn: $runtime.config.input.scroll.isEnabled)
                Toggle(L("mouseKeyboard.reverseVertical"), isOn: $runtime.config.input.scroll.reverseMouseVertical)
                Toggle(L("mouseKeyboard.reverseHorizontal"), isOn: $runtime.config.input.scroll.reverseMouseHorizontal)
                LabeledContent(L("mouseKeyboard.speed", String(format: "%.1f×", runtime.config.input.scroll.mouseSpeed))) {
                    Slider(value: $runtime.config.input.scroll.mouseSpeed, in: 0.5...4, step: 0.1).frame(width: 220)
                }
                Toggle(L("mouseKeyboard.smooth"), isOn: $runtime.config.input.scroll.smoothScrolling)
                if runtime.config.input.scroll.smoothScrolling {
                    LabeledContent(L("mouseKeyboard.smoothness")) {
                        Slider(value: $runtime.config.input.scroll.smoothness, in: 0.08...0.5).frame(width: 220)
                    }
                }
                VStack(alignment: .leading) {
                    Text(L("mouseKeyboard.scrollExcluded"))
                    AppListEditor(bundleIDs: $runtime.config.input.scroll.excludedApps)
                }
            } header: {
                Text(L("mouseKeyboard.scrolling"))
            } footer: {
                Text(L("mouseKeyboard.scrollFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($runtime.config.input.mouseButtons) { $binding in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("", isOn: $binding.isEnabled).labelsHidden().toggleStyle(.checkbox)
                            Picker("", selection: $binding.button) {
                                ForEach(MouseGestureButton.allCases.filter { $0 != .right }, id: \.self) { Text(L($0.titleKey)).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            Spacer()
                            Button(role: .destructive) { runtime.config.input.mouseButtons.removeAll { $0.id == binding.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        ActionChainEditor(actions: $binding.actions)
                    }
                }
                Button(L("mouseKeyboard.addButton")) {
                    runtime.config.input.mouseButtons.append(MouseButtonBinding(button: .middle, actions: []))
                }
            } header: {
                Text(L("mouseKeyboard.buttons"))
            } footer: {
                Text(L("mouseKeyboard.buttonsFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("hyper.enabled"), isOn: $runtime.config.input.hyper.isEnabled)
                Picker(L("hyper.trigger"), selection: $runtime.config.input.hyper.trigger) {
                    ForEach(HyperKeyTrigger.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                Toggle(L("hyper.includesShift"), isOn: $runtime.config.input.hyper.includesShift)
                Toggle(L("hyper.tapEscape"), isOn: $runtime.config.input.hyper.tapSendsEscape)
            } header: {
                Text(L("hyper.title"))
            } footer: {
                Text(L("hyper.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($runtime.config.input.remaps) { $remap in
                    HStack {
                        Toggle("", isOn: $remap.isEnabled).labelsHidden().toggleStyle(.checkbox)
                        Picker("", selection: $remap.from) {
                            ForEach(HIDKey.allCases) { Text(L($0.titleKey)).tag($0.rawValue) }
                        }
                        .labelsHidden().frame(width: 150)
                        Image(systemName: "arrow.right")
                        Picker("", selection: $remap.to) {
                            ForEach(HIDKey.allCases) { Text(L($0.titleKey)).tag($0.rawValue) }
                        }
                        .labelsHidden().frame(width: 150)
                        Picker("", selection: Binding(
                            get: { remap.vendorID.map { "\($0):\(remap.productID ?? 0)" } ?? "" },
                            set: { value in
                                let parts = value.split(separator: ":").compactMap { Int($0) }
                                remap.vendorID = parts.count == 2 ? parts[0] : nil
                                remap.productID = parts.count == 2 ? parts[1] : nil
                            }
                        )) {
                            Text(L("mouseKeyboard.allKeyboards")).tag("")
                            ForEach(InputDeviceMonitor.shared.devices.filter { $0.kind == .keyboard }) { device in
                                Text(device.name).tag("\(device.vendorID):\(device.productID)")
                            }
                        }
                        .labelsHidden()
                        Button(role: .destructive) { runtime.config.input.remaps.removeAll { $0.id == remap.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu(L("mouseKeyboard.addRemap")) {
                    Button(L("remap.preset.capsToEscape")) { addRemap(.capsLock, .escape) }
                    Button(L("remap.preset.capsToControl")) { addRemap(.capsLock, .leftControl) }
                    Button(L("remap.preset.swapOptionCommand")) {
                        addRemap(.leftOption, .leftCommand)
                        addRemap(.leftCommand, .leftOption)
                    }
                    Button(L("remap.preset.sectionToGrave")) { addRemap(.isoSection, .grave) }
                    Button(L("remap.preset.custom")) { addRemap(.rightOption, .f19) }
                }
                .fixedSize()
            } header: {
                Text(L("mouseKeyboard.remaps"))
            } footer: {
                Text(L("mouseKeyboard.remapsFooter")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addRemap(_ from: HIDKey, _ to: HIDKey) {
        runtime.config.input.remaps.append(KeyRemap(from: from.rawValue, to: to.rawValue))
    }
}

// MARK: - Menu bar

struct MenuBarPage: View {
    @Bindable var runtime: KeystivoRuntime

    var body: some View {
        Form {
            PageHeader(symbol: "menubar.rectangle", color: .indigo, titleKey: "settings.page.menuBar", subtitleKey: "menuBarSettings.subtitle")
            Section {
                Toggle(L("menuBarSettings.manager"), isOn: $runtime.config.menuBar.managerEnabled)
                Picker(L("menuBarSettings.autoCollapse"), selection: $runtime.config.menuBar.autoCollapseSeconds) {
                    Text(L("common.never")).tag(0)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("30 s").tag(30)
                }
                LabeledContent(L("action.menubar.toggleHidden")) { ActionShortcutField(runtime: runtime, actionID: "menubar.toggleHidden") }
            } header: {
                Text(L("menuBarSettings.hiding"))
            } footer: {
                Text(L("menuBarSettings.hidingFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("menuBarSettings.monitor")) {
                Toggle(L("menuBarSettings.showMonitor"), isOn: $runtime.config.menuBar.showsMonitor)
                HStack {
                    ForEach(MonitorMetric.allCases, id: \.self) { metric in
                        Toggle(L(metric.titleKey), isOn: Binding(
                            get: { runtime.config.menuBar.monitorMetrics.contains(metric) },
                            set: { on in
                                if on { runtime.config.menuBar.monitorMetrics.append(metric) } else { runtime.config.menuBar.monitorMetrics.removeAll { $0 == metric } }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                SystemMonitorDetailView()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Screen tools & displays

struct ScreenToolsPage: View {
    @Bindable var runtime: KeystivoRuntime

    var body: some View {
        Form {
            PageHeader(symbol: "viewfinder", color: .orange, titleKey: "settings.page.screenTools", subtitleKey: "screenTools.subtitle")
            Section(L("screenTools.capture")) {
                ForEach(["tools.captureText", "tools.captureImage", "tools.captureWindow", "tools.captureScreen", "tools.captureDelayed", "tools.captureHistory",
                         "tools.annotate", "tools.annotateClipboard", "tools.pinScreenshot", "tools.pickColor"], id: \.self) { id in
                    LabeledContent(L("action.\(id)")) { ActionShortcutField(runtime: runtime, actionID: id) }
                }
                Toggle(L("screenTools.annotateAfterCapture"), isOn: $runtime.config.tools.annotatesAfterCapture)
                Toggle(L("screenTools.quickAccess"), isOn: $runtime.config.tools.showsQuickAccess)
                Toggle(L("screenTools.shadow"), isOn: $runtime.config.tools.screenshotShadow)
                LabeledContent(L("screenTools.saveFolder")) {
                    HStack {
                        Text(runtime.config.tools.screenshotFolder.isEmpty ? L("screenTools.clipboardOnly") : runtime.config.tools.screenshotFolder)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(L("common.choose")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                runtime.config.tools.screenshotFolder = (url.path as NSString).abbreviatingWithTildeInPath
                            }
                        }
                        if !runtime.config.tools.screenshotFolder.isEmpty {
                            Button(L("common.remove")) { runtime.config.tools.screenshotFolder = "" }
                        }
                    }
                }
                Toggle(L("screenTools.showOCR"), isOn: $runtime.config.tools.ocrShowsResult)
                Toggle(L("screenTools.pinAfterCapture"), isOn: $runtime.config.tools.pinsAfterCapture)
                Picker(L("screenTools.colorFormat"), selection: $runtime.config.tools.colorFormat) {
                    ForEach(ColorFormat.allCases, id: \.self) { format in
                        Text(format.format(red: 0.2, green: 0.5, blue: 0.9)).tag(format)
                    }
                }
            }
            Section {
                LabeledContent(L("action.tools.recordScreen")) { ActionShortcutField(runtime: runtime, actionID: "tools.recordScreen") }
                Toggle(L("record.showsCursor"), isOn: $runtime.config.tools.recordingShowsCursor)
                Toggle(L("record.systemAudio"), isOn: $runtime.config.tools.recordingCapturesAudio)
                Toggle(L("record.microphone"), isOn: $runtime.config.tools.recordingCapturesMicrophone)
                Toggle(L("record.countdown"), isOn: $runtime.config.tools.recordingCountdown)
                Toggle(L("record.hevc"), isOn: $runtime.config.tools.recordingUsesHEVC)
                Picker(L("record.format"), selection: $runtime.config.tools.recordingFormat) {
                    ForEach(RecordingFormat.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                Picker(L("record.frameRate"), selection: $runtime.config.tools.recordingFrameRate) {
                    ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker(L("record.after"), selection: $runtime.config.tools.recordingAfter) {
                    ForEach(RecordingFinishAction.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                LabeledContent(L("record.folder")) {
                    HStack {
                        Text(runtime.config.tools.recordingFolder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(L("common.choose")) {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                runtime.config.tools.recordingFolder = (url.path as NSString).abbreviatingWithTildeInPath
                            }
                        }
                    }
                }
            } header: {
                Text(L("record.section"))
            } footer: {
                Text(L("record.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("screenTools.finder")) {
                ForEach(["finder.newFile", "finder.openTerminal", "finder.openEditor", "finder.copyPath"], id: \.self) { id in
                    LabeledContent(L("action.\(id)")) { ActionShortcutField(runtime: runtime, actionID: id) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Displays

struct DisplaysPage: View {
    @Bindable var runtime: KeystivoRuntime
    private let brightness = BrightnessController.shared

    var body: some View {
        Form {
            PageHeader(symbol: "sun.max.fill", color: .yellow, titleKey: "settings.page.displays", subtitleKey: "displays.subtitle")
            Section {
                ForEach(brightness.targets) { target in
                    BrightnessRow(target: target)
                }
                HStack {
                    if brightness.isScanning {
                        ProgressView().controlSize(.small)
                        Text(L("displays.scanning")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("displays.rescan")) { brightness.reload() }
                }
            } header: {
                Text(L("displays.brightness"))
            } footer: {
                Text(L("displays.brightnessFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("displays.brightnessKeys"), isOn: $runtime.config.tools.brightnessKeysControlExternal)
                LabeledContent(L("action.display.brightnessUp")) { ActionShortcutField(runtime: runtime, actionID: "display.brightnessUp") }
                LabeledContent(L("action.display.brightnessDown")) { ActionShortcutField(runtime: runtime, actionID: "display.brightnessDown") }
            }
            Section {
                ForEach(DisplayManager.shared.displays) { display in
                    DisplayModeRow(display: display)
                }
                Button(L("display.restoreAll")) {
                    DisplayManager.shared.restoreAll()
                    brightness.reload()
                }
            } header: {
                Text(L("screenTools.displays"))
            } footer: {
                Text(L("screenTools.displaysFooter")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            DisplayManager.shared.reload()
            if brightness.targets.isEmpty { brightness.reload() }
        }
    }
}

private struct BrightnessRow: View {
    let target: BrightnessController.Target

    private var methodBadge: (String, Color) {
        switch target.method {
        case .native: (L("displays.method.native"), .blue)
        case .ddc: (L("displays.method.ddc"), .green)
        case .software: (L("displays.method.software"), .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: CGDisplayIsBuiltin(target.id) != 0 ? "laptopcomputer" : "display")
                Text(target.name).font(.callout.weight(.semibold))
                Badge(text: methodBadge.0, color: methodBadge.1)
                Spacer()
                Text("\(Int((target.brightness * 100).rounded()))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "sun.min")
                Slider(value: Binding(
                    get: { target.brightness },
                    set: { BrightnessController.shared.setBrightness($0, for: target.id) }
                ), in: 0...1)
                Image(systemName: "sun.max")
            }
            if target.method == .ddc {
                MonitorControlsView(display: target.id)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Contrast, speaker volume and input source of a DDC monitor (MonitorControl / BetterDisplay-style).
private struct MonitorControlsView: View {
    let display: CGDirectDisplayID
    @State private var pendingInput: DDC.Input?

    var body: some View {
        let controller = BrightnessController.shared
        let controls = controller.monitorControls[display]
        VStack(alignment: .leading, spacing: 6) {
            if let contrast = controls?.contrast {
                HStack {
                    Image(systemName: "circle.lefthalf.filled").frame(width: 16)
                    Slider(value: Binding(get: { contrast }, set: { controller.setMonitorValue($0, feature: .contrast, for: display) }), in: 0...1)
                    Text("\(Int((contrast * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                .help(L("displays.contrast"))
            }
            if let volume = controls?.volume {
                HStack {
                    Image(systemName: "speaker.wave.2").frame(width: 16)
                    Slider(value: Binding(get: { volume }, set: { controller.setMonitorValue($0, feature: .volume, for: display) }), in: 0...1)
                    Text("\(Int((volume * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                .help(L("displays.speakerVolume"))
            }
            HStack {
                Image(systemName: "cable.connector").frame(width: 16)
                Menu(DDC.Input(rawValue: controls?.input ?? 0)?.title ?? L("displays.input")) {
                    ForEach(DDC.Input.allCases) { input in
                        Button(input.title) { pendingInput = input }
                    }
                }
                .fixedSize()
                .help(L("displays.inputHelp"))
                if controls == nil { ProgressView().controlSize(.small) }
            }
        }
        .font(.caption)
        .onAppear { controller.loadMonitorControls(display) }
        .confirmationDialog(L("displays.switchInputTitle", pendingInput?.title ?? ""), isPresented: Binding(get: { pendingInput != nil }, set: { if !$0 { pendingInput = nil } })) {
            Button(L("displays.switchInput")) {
                if let input = pendingInput { controller.setInput(input.rawValue, for: display) }
                pendingInput = nil
            }
            Button(L("common.cancel"), role: .cancel) { pendingInput = nil }
        } message: {
            Text(L("displays.switchInputMessage"))
        }
    }
}

private struct DisplayModeRow: View {
    let display: DisplayInfo

    var body: some View {
        HStack {
            Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
            Text(display.name).font(.callout.weight(.semibold))
            if display.isMain { Badge(text: L("display.main"), color: .blue) }
            Spacer()
            Picker("", selection: Binding(
                get: { display.currentMode?.id ?? 0 },
                set: { id in
                    guard let mode = display.modes.first(where: { $0.id == id }) else { return }
                    try? DisplayManager.shared.setMode(mode, for: display.id)
                }
            )) {
                ForEach(display.modes) { mode in Text(mode.title).tag(mode.id) }
            }
            .labelsHidden()
            .frame(width: 260)
        }
    }
}

// MARK: - Battery

struct BatteryPage: View {
    @Bindable var runtime: KeystivoRuntime
    private var limiter: ChargeLimiter { runtime.chargeLimiter }
    private let power = PowerMonitor.shared

    var body: some View {
        Form {
            PageHeader(symbol: "battery.100percent.bolt", color: .green, titleKey: "settings.page.battery", subtitleKey: "battery.subtitle")
            if !power.hasBattery {
                Section {
                    Label(L("battery.noBattery"), systemImage: "powerplug.portrait")
                        .foregroundStyle(.secondary)
                }
            } else {
                statusSection
                helperSection
                limitSection
            }
        }
        .formStyle(.grouped)
        .onAppear { limiter.refreshHelperState() }
    }

    private var statusSection: some View {
        Section(L("battery.status")) {
            LabeledContent(L("battery.level")) {
                HStack(spacing: 6) {
                    Image(systemName: power.symbolName)
                    Text(power.batteryLevel.map { "\($0)%" } ?? "—").monospacedDigit()
                }
            }
            LabeledContent(L("battery.charging")) {
                Text(L(limiter.isChargingEnabled ? (power.isCharging ? "battery.state.charging" : "battery.state.allowed") : "battery.state.paused"))
            }
            LabeledContent(L("battery.adapter")) {
                Text(L(!power.isOnAC ? "battery.adapter.unplugged" : limiter.isAdapterEnabled ? "battery.adapter.inUse" : "battery.adapter.bypassed"))
            }
            if let details = power.batteryDetails, let health = details.health {
                LabeledContent(L("battery.health")) {
                    HStack(spacing: 6) {
                        Text("\(health)%").monospacedDigit().foregroundStyle(health >= 80 ? Color.primary : Color.orange)
                        if let max = details.maxCapacity, let design = details.designCapacity {
                            Text(L("battery.capacityOf", max, design)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let health = power.batteryHealth {
                LabeledContent(L("battery.health"), value: health)
            }
            if let cycles = power.cycleCount {
                let design = power.batteryDetails?.designCycleCount
                LabeledContent(L("battery.cycles"), value: design.map { "\(cycles) / \($0)" } ?? "\(cycles)")
            }
            if let details = power.batteryDetails {
                if let temperature = details.temperature {
                    LabeledContent(L("battery.temperature"), value: Measurement(value: temperature, unit: UnitTemperature.celsius)
                        .formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(1))).locale(Localizer.shared.locale)))
                }
                if let watts = details.power, abs(watts) >= 0.1 {
                    LabeledContent(L(watts > 0 ? "battery.chargingPower" : "battery.drawPower"), value: String(format: "%.1f W", abs(watts)))
                }
                if let adapter = details.adapterWatts, power.isOnAC {
                    LabeledContent(L("battery.adapterPower"), value: "\(adapter) W")
                }
                if let date = details.manufactureDate {
                    LabeledContent(L("battery.manufactured"), value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Localizer.shared.locale)))
                }
            }
        }
    }

    private var helperSection: some View {
        Section {
            switch limiter.helperState {
            case .installed:
                LabeledContent(L("battery.helper")) {
                    HStack {
                        Badge(text: L("battery.helper.installed"), color: .green)
                        Button(L("battery.helper.uninstall")) { Task { await limiter.uninstallHelper() } }
                    }
                }
            case .requiresApproval:
                LabeledContent(L("battery.helper")) {
                    HStack {
                        Badge(text: L("battery.helper.approval"), color: .orange)
                        Button(L("battery.helper.openSettings")) { SMAppService.openSystemSettingsLoginItems() }
                        Button(L("common.refresh")) { limiter.refreshHelperState() }
                    }
                }
            case .notInstalled:
                LabeledContent(L("battery.helper")) {
                    Button(L("battery.helper.install")) { limiter.installHelper() }
                        .buttonStyle(.borderedProminent)
                }
            case .unsupported:
                Label(L("battery.unsupported"), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(L("battery.helper.failed"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(L("battery.helper.install")) { limiter.installHelper() }
                }
            }
        } header: {
            Text(L("battery.helperSection"))
        } footer: {
            Text(L("battery.helperFooter")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var limitSection: some View {
        Section {
            Toggle(L("battery.limitEnabled"), isOn: $runtime.config.system.chargeLimit.isEnabled)
                .disabled(limiter.helperState != .installed)
            LabeledContent(L("battery.limit")) {
                HStack {
                    Slider(value: Binding(
                        get: { Double(runtime.config.system.chargeLimit.limit) },
                        set: { runtime.config.system.chargeLimit.limit = Int($0) }
                    ), in: 50...100, step: 5)
                    .frame(width: 220)
                    Text("\(runtime.config.system.chargeLimit.limit)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Stepper(value: $runtime.config.system.chargeLimit.sailingRange, in: 0...15) {
                LabeledContent(L("battery.sailing"), value: L("battery.sailingValue", runtime.config.system.chargeLimit.sailingRange))
            }
            Toggle(L("battery.discharge"), isOn: $runtime.config.system.chargeLimit.dischargesAboveLimit)
            Toggle(L("battery.pauseDuringSleep"), isOn: $runtime.config.system.chargeLimit.pausesChargingDuringSleep)
            HStack {
                Button(L("action.battery.topUp")) { limiter.topUp() }
                    .disabled(!runtime.config.system.chargeLimit.isEnabled || limiter.isToppingUp)
                if limiter.isToppingUp { Badge(text: L("cc.toppingUp"), color: .green) }
            }
            LabeledContent(L("action.battery.toggleLimit")) { ActionShortcutField(runtime: runtime, actionID: "battery.toggleLimit") }
        } header: {
            Text(L("battery.limitSection"))
        } footer: {
            Text(L("battery.limitFooter")).font(.caption).foregroundStyle(.secondary)
        }
        .disabled(limiter.helperState != .installed)
    }
}

// MARK: - Files

struct FilesPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var editing: FolderRule?

    var body: some View {
        Form {
            PageHeader(symbol: "folder.fill.badge.gearshape", color: .blue, titleKey: "settings.page.files", subtitleKey: "files.subtitle")
            Section {
                Toggle(L("files.rulesEnabled"), isOn: $runtime.config.files.rulesEnabled)
                ForEach($runtime.config.files.folderRules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.isEnabled).labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name)
                            Text("\(rule.folderPath) · \(L("files.conditionsCount", rule.conditions.count)) · \(L("files.actionsCount", rule.actions.count))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("files.preview")) {
                            let matches = FolderRuleEngine.shared.run(rule, dryRun: true)
                            runtime.hud.show(symbol: "eye", text: L("files.previewResult", matches.count))
                        }
                        Button(L("shortcuts.edit")) { editing = rule }
                        Button(role: .destructive) { runtime.config.files.folderRules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button(L("files.addRule")) {
                        let rule = FolderRule(name: L("files.newRule"), folderPath: "~/Downloads", conditions: [.kind(.image)], actions: [.moveTo("~/Pictures")])
                        runtime.config.files.folderRules.append(rule)
                        editing = rule
                    }
                    Menu(L("files.templates")) {
                        ForEach(FolderRuleEngine.templates) { template in
                            Button(template.name) { runtime.config.files.folderRules.append(template) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button(L("action.files.runRules")) { FolderRuleEngine.shared.runAll() }
                }
            } header: {
                Text(L("files.rules"))
            } footer: {
                Text(L("files.rulesFooter")).font(.caption).foregroundStyle(.secondary)
            }
            if !FolderRuleEngine.shared.history.isEmpty {
                Section(L("files.history")) {
                    ForEach(FolderRuleEngine.shared.history.prefix(20)) { record in
                        HStack {
                            Image(systemName: record.succeeded ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(record.succeeded ? .green : .orange)
                            Text(record.fileName).lineLimit(1)
                            Text(record.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(record.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section(L("files.shelf")) {
                Toggle(L("files.shelfOnDrag"), isOn: $runtime.config.files.shelfOnDrag)
                LabeledContent(L("action.files.toggleShelf")) { ActionShortcutField(runtime: runtime, actionID: "files.toggleShelf") }
            }
            Section(L("files.uninstaller")) {
                Text(L("uninstall.intro")).font(.caption).foregroundStyle(.secondary)
                Button(L("action.files.uninstallApp")) { runtime.windowsUI.showUninstaller() }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            FolderRuleEditor(rule: rule) { result in
                if let result, let index = runtime.config.files.folderRules.firstIndex(where: { $0.id == result.id }) {
                    runtime.config.files.folderRules[index] = result
                }
                editing = nil
            }
        }
    }
}

private struct FolderRuleEditor: View {
    @State var rule: FolderRule
    let onDone: (FolderRule?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("files.ruleName"), text: $rule.name)
                    HStack {
                        TextField(L("files.folder"), text: $rule.folderPath)
                        Button(L("picker.browse")) { if let path = chooseFolder() { rule.folderPath = path } }
                    }
                }
                Section(L("files.when")) {
                    Picker(L("automation.match"), selection: $rule.matchesAll) {
                        Text(L("automation.matchAll")).tag(true)
                        Text(L("automation.matchAny")).tag(false)
                    }
                    .pickerStyle(.segmented).fixedSize()
                    ForEach(rule.conditions.indices, id: \.self) { index in
                        HStack {
                            ConditionEditor(condition: $rule.conditions[index])
                            Spacer()
                            Button { rule.conditions.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                    Menu(L("automation.addCondition")) {
                        Button(L("fileCondition.nameContains")) { rule.conditions.append(.nameContains("")) }
                        Button(L("fileCondition.nameMatches")) { rule.conditions.append(.nameMatches("*.png")) }
                        Button(L("fileCondition.extensionIs")) { rule.conditions.append(.extensionIs(["pdf"])) }
                        Button(L("fileCondition.kind")) { rule.conditions.append(.kind(.image)) }
                        Button(L("fileCondition.addedMoreThanDaysAgo")) { rule.conditions.append(.addedMoreThanDaysAgo(7)) }
                        Button(L("fileCondition.largerThanMB")) { rule.conditions.append(.largerThanMB(100)) }
                    }
                    .fixedSize()
                }
                Section(L("files.then")) {
                    ForEach(rule.actions.indices, id: \.self) { index in
                        HStack {
                            FileActionEditor(action: $rule.actions[index])
                            Spacer()
                            Button { rule.actions.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                    Menu(L("automation.addStep")) {
                        Button(L("fileAction.moveTo")) { rule.actions.append(.moveTo("~/Documents")) }
                        Button(L("fileAction.copyTo")) { rule.actions.append(.copyTo("~/Documents")) }
                        Button(L("fileAction.rename")) { rule.actions.append(.rename("{date} {name}")) }
                        Button(L("fileAction.addTag")) { rule.actions.append(.addTag("Keystivo")) }
                        Button(L("fileAction.moveToTrash")) { rule.actions.append(.moveToTrash) }
                        Button(L("fileAction.openWith")) { rule.actions.append(.openWith("")) }
                        Button(L("fileAction.runShellScript")) { rule.actions.append(.runShellScript("echo \"$1\"")) }
                        Button(L("fileAction.notify")) { rule.actions.append(.notify) }
                    }
                    .fixedSize()
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L("common.cancel")) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(L("common.save")) { onDone(rule) }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct ConditionEditor: View {
    @Binding var condition: FileCondition

    var body: some View {
        HStack {
            Text(L("fileCondition.\(condition.kindKey)"))
            switch condition {
            case .nameContains(let text):
                TextField("", text: Binding(get: { text }, set: { condition = .nameContains($0) })).frame(width: 160)
            case .nameMatches(let pattern):
                TextField("", text: Binding(get: { pattern }, set: { condition = .nameMatches($0) })).frame(width: 160)
            case .extensionIs(let list):
                TextField("pdf, png", text: Binding(get: { list.joined(separator: ", ") }, set: { condition = .extensionIs($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) })).frame(width: 160)
            case .kind(let kind):
                Picker("", selection: Binding(get: { kind }, set: { condition = .kind($0) })) {
                    ForEach(FileKind.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                .labelsHidden().fixedSize()
            case .addedMoreThanDaysAgo(let days):
                Stepper(L("files.days", days), value: Binding(get: { days }, set: { condition = .addedMoreThanDaysAgo($0) }), in: 0...365)
            case .largerThanMB(let megabytes):
                TextField("", value: Binding(get: { megabytes }, set: { condition = .largerThanMB($0) }), format: .number).frame(width: 80)
                Text("MB")
            }
        }
    }
}

private struct FileActionEditor: View {
    @Binding var action: FileAction

    var body: some View {
        HStack {
            Text(L("fileAction.\(action.kindKey)"))
            switch action {
            case .moveTo(let path):
                TextField("", text: Binding(get: { path }, set: { action = .moveTo($0) })).frame(width: 200)
            case .copyTo(let path):
                TextField("", text: Binding(get: { path }, set: { action = .copyTo($0) })).frame(width: 200)
            case .rename(let pattern):
                TextField("{date} {name}", text: Binding(get: { pattern }, set: { action = .rename($0) })).frame(width: 200)
            case .addTag(let tag):
                TextField("", text: Binding(get: { tag }, set: { action = .addTag($0) })).frame(width: 140)
            case .openWith(let bundleID):
                AppPickerButton(bundleID: Binding(get: { bundleID }, set: { action = .openWith($0) }))
            case .runShellScript(let script):
                TextField("", text: Binding(get: { script }, set: { action = .runShellScript($0) })).font(.caption.monospaced()).frame(width: 240)
            case .moveToTrash, .notify:
                EmptyView()
            }
        }
    }
}

// MARK: - Links

struct LinksPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var isDefault = LinkRouter.isDefaultBrowser

    var body: some View {
        let browsers = LinkRouter.installedBrowsers()
        Form {
            PageHeader(symbol: "link.circle.fill", color: .blue, titleKey: "settings.page.links", subtitleKey: "links.subtitle")
            Section {
                HStack {
                    Label(L(isDefault ? "links.isDefault" : "links.notDefault"), systemImage: isDefault ? "checkmark.seal.fill" : "exclamationmark.circle")
                        .foregroundStyle(isDefault ? .green : .orange)
                    Spacer()
                    if !isDefault {
                        Button(L("action.links.makeDefaultBrowser")) {
                            Task {
                                try? await LinkRouter.becomeDefaultBrowser()
                                isDefault = LinkRouter.isDefaultBrowser
                            }
                        }
                    }
                }
                Toggle(L("links.enabled"), isOn: $runtime.config.links.isEnabled)
                Picker(L("links.fallback"), selection: $runtime.config.links.fallback) {
                    ForEach(LinkSettings.Fallback.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                Picker(L("links.defaultBrowser"), selection: $runtime.config.links.defaultBrowserBundleID) {
                    Text(L("common.none")).tag(String?.none)
                    ForEach(browsers) { browser in Text(browser.name).tag(Optional(browser.bundleID)) }
                }
                Toggle(L("links.stripTracking"), isOn: $runtime.config.links.stripsTrackingParameters)
                Toggle(L("links.optionPicker"), isOn: $runtime.config.links.optionShowsPicker)
            } footer: {
                Text(L("links.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("links.rules")) {
                ForEach($runtime.config.links.rules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.isEnabled).labelsHidden().toggleStyle(.checkbox)
                        TextField(L("links.hostPattern"), text: $rule.hostPattern).frame(width: 170)
                        AppPickerButton(bundleID: Binding(get: { rule.sourceBundleID ?? "" }, set: { rule.sourceBundleID = $0.isEmpty ? nil : $0 }), placeholderKey: "links.anySource")
                        Image(systemName: "arrow.right")
                        Picker("", selection: $rule.browserBundleID) {
                            ForEach(browsers) { browser in Text(browser.name).tag(browser.bundleID) }
                        }
                        .labelsHidden().frame(width: 150)
                        Button(role: .destructive) { runtime.config.links.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button(L("links.addRule")) {
                    runtime.config.links.rules.append(LinkRule(hostPattern: "example.com", browserBundleID: browsers.first?.bundleID ?? "com.apple.Safari"))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { isDefault = LinkRouter.isDefaultBrowser }
    }
}

// MARK: - Presentation

struct PresentationPage: View {
    @Bindable var runtime: KeystivoRuntime

    var body: some View {
        Form {
            PageHeader(symbol: "play.rectangle.fill", color: .red, titleKey: "settings.page.presentation", subtitleKey: "presentation.subtitle")
            Section {
                Toggle(L("presentation.keystrokes"), isOn: $runtime.config.presentation.showsKeystrokes)
                Toggle(L("presentation.onlyShortcuts"), isOn: $runtime.config.presentation.onlyShortcuts)
                    .disabled(!runtime.config.presentation.showsKeystrokes)
                Toggle(L("presentation.clicks"), isOn: $runtime.config.presentation.showsClicks)
                Toggle(L("presentation.cursor"), isOn: $runtime.config.presentation.highlightsCursor)
            } footer: {
                Text(L("presentation.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(L("action.presentation.toggleKeystrokes")) { ActionShortcutField(runtime: runtime, actionID: "presentation.toggleKeystrokes") }
                LabeledContent(L("action.presentation.toggleCursor")) { ActionShortcutField(runtime: runtime, actionID: "presentation.toggleCursor") }
            }
        }
        .formStyle(.grouped)
    }
}
