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

// MARK: - Keyboard navigation

struct NavigationPage: View {
    @Bindable var runtime: KeystivoRuntime

    var body: some View {
        Form {
            PageHeader(symbol: "keyboard.fill", color: .teal, titleKey: "settings.page.navigation", subtitleKey: "navigationSettings.subtitle")
            Section(L("navigationSettings.shortcuts")) {
                LabeledContent(L("action.navigation.hints")) { ActionShortcutField(runtime: runtime, actionID: "navigation.hints") }
                LabeledContent(L("action.navigation.search")) { ActionShortcutField(runtime: runtime, actionID: "navigation.search") }
                LabeledContent(L("action.navigation.scroll")) { ActionShortcutField(runtime: runtime, actionID: "navigation.scroll") }
            }
            Section(L("navigationSettings.labels")) {
                TextField(L("navigationSettings.alphabet"), text: $runtime.config.navigation.alphabet)
                    .font(.system(.body, design: .monospaced))
                if Set(runtime.config.navigation.alphabet.lowercased().filter(\.isLetter)).count < 2 {
                    Label(L("navigationSettings.alphabetInvalid"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Button(L("navigationSettings.resetAlphabet")) { runtime.config.navigation.alphabet = HintLabelGenerator.defaultAlphabet }
                Picker(L("navigationSettings.style"), selection: $runtime.config.navigation.hintStyle) {
                    ForEach(HintStyle.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(L("navigationSettings.size", runtime.config.navigation.hintSize.safeInt)) {
                    Slider(value: $runtime.config.navigation.hintSize, in: 9...20, step: 1).frame(width: 220)
                }
                Toggle(L("navigationSettings.menuBar"), isOn: $runtime.config.navigation.includesMenuBar)
                Toggle(L("navigationSettings.dock"), isOn: $runtime.config.navigation.includesDock)
            }
            Section(L("navigationSettings.scrolling")) {
                LabeledContent(L("navigationSettings.scrollStep", runtime.config.navigation.scrollStep.safeInt)) {
                    Slider(value: $runtime.config.navigation.scrollStep, in: 20...200, step: 10).frame(width: 220)
                }
            }
            Section(L("navigationSettings.howTo")) {
                Text(L("navigationSettings.howToBody")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Gestures

// MARK: - Audio

struct AudioPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var newProfileName = ""

    var body: some View {
        Form {
            PageHeader(symbol: "speaker.wave.2.fill", color: .pink, titleKey: "settings.page.audio", subtitleKey: "audioSettings.subtitle")
            Section(L("audioSettings.mixer")) {
                MixerView(runtime: runtime)
            }
            Section {
                Toggle(L("audioSettings.appVolume"), isOn: $runtime.config.audio.appVolumeEnabled)
                LabeledContent(L("audioSettings.permission")) {
                    PermissionBadge(kind: .audioCapture)
                }
                Picker(L("audioSettings.step"), selection: $runtime.config.audio.volumeStep) {
                    Text("2%").tag(0.02)
                    Text("5%").tag(0.05)
                    Text("6.25% (macOS)").tag(1.0 / 16.0)
                    Text("10%").tag(0.1)
                }
            } header: {
                Text(L("audioSettings.perApp"))
            } footer: {
                Text(L("audioSettings.perAppFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("audioSettings.shortcuts")) {
                ForEach(["audio.volumeUp", "audio.volumeDown", "audio.toggleMute", "audio.cycleOutput", "audio.toggleMic", "audio.frontAppVolumeUp", "audio.frontAppVolumeDown", "audio.frontAppToggleMute", "audio.showMixer"], id: \.self) { id in
                    LabeledContent(L("action.\(id)")) { ActionShortcutField(runtime: runtime, actionID: id) }
                }
            }
            Section {
                HStack {
                    TextField(L("audioSettings.profileName"), text: $newProfileName)
                    Button(L("audioSettings.saveCurrent")) {
                        let name = newProfileName.isEmpty ? L("audioSettings.defaultProfileName", runtime.config.audio.profiles.count + 1) : newProfileName
                        runtime.config.audio.profiles.append(AudioProfileApplier.capture(name: name))
                        newProfileName = ""
                    }
                }
                ForEach($runtime.config.audio.profiles) { $profile in
                    HStack {
                        SymbolPicker(symbol: $profile.symbolName)
                        TextField("", text: $profile.name).textFieldStyle(.plain)
                        Spacer()
                        Text(profileSummary(profile)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button(L("audioSettings.apply")) { AudioProfileApplier.apply(profile) }
                        Button(role: .destructive) { endEditing(); runtime.config.audio.profiles.removeAll { $0.id == profile.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text(L("audioSettings.profiles"))
            } footer: {
                Text(L("audioSettings.profilesFooter")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func profileSummary(_ profile: AudioProfile) -> String {
        var parts: [String] = []
        if let uid = profile.outputDeviceUID { parts.append(AudioDeviceManager.shared.outputDevices.first { $0.uid == uid }?.name ?? uid) }
        if let volume = profile.outputVolume { parts.append("\((volume * 100).safeInt)%") }
        if let mix = profile.appSettings, !mix.isEmpty { parts.append(L("audioSettings.appsInMix", mix.count)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - System

struct SystemPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var addingRule = false

    var body: some View {
        let power = PowerMonitor.shared
        Form {
            PageHeader(symbol: "cpu.fill", color: .gray, titleKey: "settings.page.system", subtitleKey: "systemSettings.subtitle")
            Section(L("systemSettings.battery")) {
                if power.hasBattery {
                    LabeledContent(L("systemSettings.level"), value: "\(power.batteryLevel ?? 0)%\(power.isCharging ? " ⚡︎" : "")")
                    if let cycles = power.cycleCount { LabeledContent(L("systemSettings.cycles"), value: "\(cycles)") }
                    if let health = power.batteryHealth { LabeledContent(L("systemSettings.health"), value: health) }
                } else {
                    Text(L("cc.onPower"))
                }
                LabeledContent(L("systemSettings.lowPower"), value: L(power.isLowPowerMode ? "common.on" : "common.off"))
                Picker(L("systemSettings.keepAwake"), selection: Binding(get: { KeepAwakeController.shared.mode }, set: { KeepAwakeController.shared.isSetByProfile = false; KeepAwakeController.shared.set($0) })) {
                    Text(L("keepAwake.off.title")).tag(KeepAwakeMode.off)
                    Text(L(KeepAwakeMode.system.titleKey)).tag(KeepAwakeMode.system)
                    Text(L(KeepAwakeMode.display.titleKey)).tag(KeepAwakeMode.display)
                }
            }
            Section {
                Toggle(L("systemSettings.autoPower"), isOn: $runtime.config.system.autoSwitchesPowerProfiles)
                ForEach($runtime.config.system.powerProfiles) { $profile in
                    PowerProfileEditor(runtime: runtime, profile: $profile)
                }
                Button(L("systemSettings.addPowerProfile")) {
                    runtime.config.system.powerProfiles.append(PowerProfile(name: L("systemSettings.newPowerProfile")))
                }
            } header: {
                Text(L("systemSettings.powerProfiles"))
            }
            Section {
                Toggle(L("systemSettings.rememberSource"), isOn: $runtime.config.system.remembersInputSourcePerApp)
                ForEach(runtime.config.system.inputSourceRules.sorted(by: { $0.key < $1.key }), id: \.key) { bundleID, sourceID in
                    HStack {
                        AppIconView(bundleID: bundleID, size: 18)
                        Text(AppDisplayName.name(forBundleID: bundleID) ?? bundleID)
                        Spacer()
                        Picker("", selection: Binding(get: { sourceID }, set: { runtime.config.system.inputSourceRules[bundleID] = $0 })) {
                            ForEach(InputSourceManager.shared.sources) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 200)
                        Button(role: .destructive) { runtime.config.system.inputSourceRules[bundleID] = nil } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Button(L("systemSettings.addInputRule")) { addingRule = true }
                    .popover(isPresented: $addingRule) {
                        AppPickerList { bundleID in
                            runtime.config.system.inputSourceRules[bundleID] = InputSourceManager.shared.currentID ?? InputSourceManager.shared.sources.first?.id
                            addingRule = false
                        }
                    }
            } header: {
                Text(L("systemSettings.inputSources"))
            }
            Section {
                ForEach(InputDeviceMonitor.shared.devices) { device in
                    HStack {
                        Image(systemName: device.kind == .keyboard ? "keyboard" : (device.kind == .trackpad ? "rectangle.and.hand.point.up.left" : "computermouse"))
                        Text(device.name)
                        Spacer()
                        Button(L("systemSettings.addDeviceProfile")) {
                            runtime.config.system.deviceProfiles.append(InputDeviceProfile(deviceMatch: device.name))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ForEach($runtime.config.system.deviceProfiles) { $profile in
                    DeviceProfileEditor(profile: $profile) {
                        endEditing(); runtime.config.system.deviceProfiles.removeAll { $0.id == profile.id }
                    }
                }
            } header: {
                Text(L("systemSettings.devices"))
            } footer: {
                Text(L("systemSettings.devicesFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("systemSettings.commands")) {
                ForEach(SystemCommand.allCases) { command in
                    LabeledContent {
                        HStack {
                            ActionShortcutField(runtime: runtime, actionID: "system.\(command.rawValue)")
                            Button(L("launcher.action.run")) {
                                ActionRegistry.shared.run(ActionInvocation("system.\(command.rawValue)"), source: .menuBar)
                            }
                            .disabled(command.isDestructive)
                        }
                    } label: {
                        Label(L(command.titleKey), systemImage: command.symbolName)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PowerProfileEditor: View {
    let runtime: KeystivoRuntime
    @Binding var profile: PowerProfile

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Picker(L("systemSettings.keepAwake"), selection: $profile.keepAwake) {
                    Text(L("keepAwake.off.title")).tag(KeepAwakeMode.off)
                    Text(L(KeepAwakeMode.system.titleKey)).tag(KeepAwakeMode.system)
                    Text(L(KeepAwakeMode.display.titleKey)).tag(KeepAwakeMode.display)
                }
                Picker(L("systemSettings.autoApplyOn"), selection: $profile.autoApplyOn) {
                    Text(L("common.never")).tag(String?.none)
                    Text(L("power.source.battery")).tag(Optional("battery"))
                    Text(L("power.source.ac")).tag(Optional("ac"))
                }
                Toggle(L("systemSettings.suspendAudio"), isOn: $profile.suspendsAppAudio)
                Toggle(L("systemSettings.pauseClipboard"), isOn: $profile.pausesClipboard)
                Text(L("systemSettings.quitApps")).font(.caption)
                AppListEditor(bundleIDs: $profile.quitApps)
                Text(L("systemSettings.hideApps")).font(.caption)
                AppListEditor(bundleIDs: $profile.hideApps)
                HStack {
                    Button(L("audioSettings.apply")) { runtime.applyPowerProfile(profile) }
                    Spacer()
                    if !PowerProfile.builtIn.contains(where: { $0.id == profile.id }) {
                        Button(L("common.delete"), role: .destructive) {
                            endEditing(); runtime.config.system.powerProfiles.removeAll { $0.id == profile.id }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                SymbolPicker(symbol: $profile.symbolName)
                TextField("", text: $profile.name).textFieldStyle(.plain)
                if runtime.config.system.activePowerProfileID == profile.id { Badge(text: L("profiles.active"), color: .green) }
            }
        }
    }
}

private struct DeviceProfileEditor: View {
    @Binding var profile: InputDeviceProfile
    let onDelete: () -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Picker(L("profiles.inputSource"), selection: $profile.inputSourceID) {
                    Text(L("common.none")).tag(String?.none)
                    ForEach(InputSourceManager.shared.sources) { Text($0.name).tag(Optional($0.id)) }
                }
                Text(L("systemSettings.onConnect")).font(.caption)
                ActionChainEditor(actions: $profile.onConnect)
                Text(L("systemSettings.onDisconnect")).font(.caption)
                ActionChainEditor(actions: $profile.onDisconnect)
                Button(L("common.delete"), role: .destructive, action: onDelete)
            }
        } label: {
            HStack {
                Toggle("", isOn: $profile.isEnabled).labelsHidden().toggleStyle(.checkbox)
                TextField(L("systemSettings.deviceMatch"), text: $profile.deviceMatch).textFieldStyle(.plain)
            }
        }
    }
}

/// Colored status pill for a permission.
struct PermissionBadge: View {
    let kind: PermissionKind

    var body: some View {
        let status = PermissionCenter.shared.status(kind)
        let (text, color): (String, Color) = switch status {
        case .granted: (L("permissions.status.granted"), .green)
        case .denied: (L("permissions.status.denied"), .red)
        case .notDetermined: (L("permissions.status.notDetermined"), .orange)
        case .unknown: (L("permissions.status.unknown"), .gray)
        }
        Badge(text: text, color: color)
    }
}
