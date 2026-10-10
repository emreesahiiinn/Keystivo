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

// MARK: - General

struct GeneralPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var confirmReset = false

    var body: some View {
        Form {
            PageHeader(symbol: "gearshape.fill", color: .gray, titleKey: "settings.page.general", subtitleKey: "general.subtitle")
            Section(L("general.language")) {
                Picker(L("general.interfaceLanguage"), selection: $runtime.config.general.language) {
                    Text(L("general.language.system")).tag(AppLanguage.systemCode)
                    Divider()
                    ForEach(AppLanguage.supported) { language in
                        Text(language.nativeName).tag(language.code)
                    }
                }
                Text(L("general.language.note")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("general.startup")) {
                Toggle(L("general.launchAtLogin"), isOn: $runtime.config.general.launchAtLogin)
                Toggle(L("general.menuBarIcon"), isOn: $runtime.config.general.showsMenuBarIcon)
                Toggle(L("general.dockIcon"), isOn: $runtime.config.general.showsDockIcon)
            }
            Section(L("general.appearance")) {
                Picker(L("general.theme"), selection: $runtime.config.general.appearance) {
                    ForEach(AppearancePreference.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("general.hud"), isOn: $runtime.config.general.showsHUD)
            }
            Section {
                LabeledContent(L("general.launcherShortcut")) { ActionShortcutField(runtime: runtime, actionID: "launcher.show") }
                Button(L("general.showWelcome")) { runtime.windowsUI.showOnboarding() }
                Button(L("general.reset"), role: .destructive) { confirmReset = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L("general.reset.confirm"), isPresented: $confirmReset) {
            Button(L("general.reset"), role: .destructive) { runtime.store.resetToDefaults() }
        } message: {
            Text(L("general.reset.message"))
        }
    }
}

// MARK: - Profiles

struct ProfilesPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(runtime.config.workspace.profiles) { profile in
                        HStack {
                            Image(systemName: profile.symbolName).foregroundStyle(Theme.color(named: profile.colorName))
                            Text(profile.name)
                            Spacer()
                            if profile.id == runtime.config.workspace.activeProfileID {
                                Badge(text: L("profiles.active"), color: .green)
                            }
                        }
                        .tag(profile.id)
                    }
                    .onMove { runtime.config.workspace.profiles.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack {
                    Button {
                        let profile = UserProfile(name: L("profiles.new"), symbolName: "person.fill", colorName: Theme.colorNames.randomElement() ?? "blue")
                        runtime.config.workspace.profiles.append(profile)
                        selection = profile.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let selection, runtime.config.workspace.profiles.count > 1 else { return }
                        runtime.config.workspace.profiles.removeAll { $0.id == selection }
                        if runtime.config.workspace.activeProfileID == selection {
                            runtime.config.workspace.activeProfileID = runtime.config.workspace.profiles.first?.id
                        }
                        self.selection = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil || runtime.config.workspace.profiles.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, maxWidth: 260)

            Group {
                if let index = runtime.config.workspace.profiles.firstIndex(where: { $0.id == selection }) {
                    ProfileEditor(runtime: runtime, profile: $runtime.config.workspace.profiles[index])
                } else {
                    ContentUnavailableView(L("profiles.selectTitle"), systemImage: "person.2", description: Text(L("profiles.selectBody")))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selection = selection ?? runtime.config.workspace.activeProfileID }
    }
}

private struct ProfileEditor: View {
    let runtime: KeystivoRuntime
    @Binding var profile: UserProfile

    var body: some View {
        Form {
            Section {
                HStack {
                    SymbolPicker(symbol: $profile.symbolName)
                    TextField(L("profiles.name"), text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                    Button(L("profiles.activate")) { runtime.profiles.activate(profile.id) }
                        .disabled(profile.id == runtime.config.workspace.activeProfileID)
                }
                ColorNamePicker(colorName: $profile.colorName)
                Text(L("profiles.explanation")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("profiles.onActivate")) {
                Picker(L("profiles.audioProfile"), selection: $profile.audioProfileID) {
                    Text(L("common.none")).tag(UUID?.none)
                    ForEach(runtime.config.audio.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(L("profiles.powerProfile"), selection: $profile.powerProfileID) {
                    Text(L("common.none")).tag(String?.none)
                    ForEach(runtime.config.system.powerProfiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(L("profiles.layout"), selection: $profile.layoutID) {
                    Text(L("common.none")).tag(UUID?.none)
                    ForEach(runtime.config.windows.layouts) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(L("profiles.inputSource"), selection: $profile.inputSourceID) {
                    Text(L("common.none")).tag(String?.none)
                    ForEach(InputSourceManager.shared.sources) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle(L("profiles.startsFocus"), isOn: $profile.startsFocus)
            }
            Section(L("profiles.launchApps")) { AppListEditor(bundleIDs: $profile.launchApps) }
            Section(L("profiles.quitApps")) { AppListEditor(bundleIDs: $profile.quitApps) }
            Section(L("profiles.hideApps")) { AppListEditor(bundleIDs: $profile.hideApps) }
            Section(L("profiles.actions")) { ActionChainEditor(actions: $profile.activationActions) }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutsPage: View {
    @Bindable var runtime: KeystivoRuntime
    let navigation: SettingsNavigation
    @State private var editing: HotkeyBinding?
    @State private var filter = ""
    @State private var confirmRestore = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                PageHeader(symbol: "command", color: .indigo, titleKey: "settings.page.shortcuts", subtitleKey: "shortcuts.subtitle")
                if !conflicts.isEmpty {
                    Section(L("shortcuts.conflicts")) {
                        ForEach(conflicts) { conflict in
                            ConflictRow(conflict: conflict)
                        }
                    }
                }
                Section {
                    ForEach(filtered) { binding in
                        ShortcutRow(runtime: runtime, binding: binding, failure: runtime.hotkeys.failures[binding.id]) {
                            editing = binding
                        }
                    }
                } header: {
                    HStack {
                        Text(L("shortcuts.list", runtime.config.hotkeys.count))
                        Spacer()
                        TextField(L("shortcuts.filter"), text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button {
                    editing = HotkeyBinding(nil, "launcher.show")
                } label: { Label(L("shortcuts.add"), systemImage: "plus") }
                Spacer()
                Button(L("shortcuts.restoreDefaults")) { confirmRestore = true }
            }
            .padding(12)
        }
        .sheet(item: $editing) { binding in
            HotkeyBindingEditor(runtime: runtime, binding: binding) { result in
                if let result {
                    if let index = runtime.config.hotkeys.firstIndex(where: { $0.id == result.id }) {
                        runtime.config.hotkeys[index] = result
                    } else {
                        runtime.config.hotkeys.append(result)
                    }
                }
                editing = nil
            } onDelete: {
                runtime.config.hotkeys.removeAll { $0.id == binding.id }
                editing = nil
            }
        }
        .confirmationDialog(L("shortcuts.restoreDefaults"), isPresented: $confirmRestore) {
            Button(L("shortcuts.restoreDefaults"), role: .destructive) { runtime.config.hotkeys = ConfigurationStore.defaultHotkeys() }
        }
        .onAppear {
            if let actionID = navigation.pendingBindingActionID {
                navigation.pendingBindingActionID = nil
                editing = HotkeyBinding(nil, actionID)
            }
        }
    }

    private var filtered: [HotkeyBinding] {
        guard !filter.isEmpty else { return runtime.config.hotkeys }
        return runtime.config.hotkeys.filter { binding in
            let title = binding.name.isEmpty ? binding.actions.map { ActionRegistry.shared.title(for: $0) }.joined(separator: " ") : binding.name
            return FuzzyMatcher.match(filter, in: title) != nil || (binding.combo?.displayString.contains(filter) ?? false)
        }
    }

    private var conflicts: [BindingConflict] {
        ConflictReport.make(runtime: runtime).filter {
            if case .keyCombo = $0.first.trigger { return $0.severity != .override }
            return false
        }
    }
}

private struct ShortcutRow: View {
    @Bindable var runtime: KeystivoRuntime
    let binding: HotkeyBinding
    let failure: String?
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { binding.isEnabled },
                set: { value in update { $0.isEnabled = value } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            if let first = binding.actions.first, let descriptor = ActionRegistry.shared.descriptor(first.actionID) {
                Image(systemName: descriptor.symbolName).frame(width: 18).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                HStack(spacing: 6) {
                    if !binding.appBundleIDs.isEmpty {
                        Label(binding.appBundleIDs.compactMap(AppDisplayName.name(forBundleID:)).joined(separator: ", "), systemImage: "app")
                    }
                    if !binding.profileIDs.isEmpty {
                        Label(runtime.config.workspace.profiles.filter { binding.profileIDs.contains($0.id) }.map(\.name).joined(separator: ", "), systemImage: "person.crop.circle")
                    }
                    if binding.actions.count > 1 {
                        Label(L("shortcuts.chain", binding.actions.count), systemImage: "link")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let failure {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(failure)
            }
            KeyRecorder(combo: Binding(get: { binding.combo }, set: { combo in update { $0.combo = combo } }))
            Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help(L("shortcuts.edit"))
        }
    }

    private var title: String {
        if !binding.name.isEmpty { return binding.name }
        return binding.actions.map { ActionRegistry.shared.title(for: $0) }.joined(separator: " → ")
    }

    private func update(_ change: (inout HotkeyBinding) -> Void) {
        guard let index = runtime.config.hotkeys.firstIndex(where: { $0.id == binding.id }) else { return }
        change(&runtime.config.hotkeys[index])
    }
}

struct HotkeyBindingEditor: View {
    let runtime: KeystivoRuntime
    @State var binding: HotkeyBinding
    let onDone: (HotkeyBinding?) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("shortcuts.name"), text: $binding.name, prompt: Text(L("shortcuts.namePlaceholder")))
                    LabeledContent(L("shortcuts.shortcut")) { KeyRecorder(combo: $binding.combo) }
                    Toggle(L("shortcuts.enabled"), isOn: $binding.isEnabled)
                }
                Section(L("shortcuts.actions")) {
                    ActionChainEditor(actions: $binding.actions)
                }
                Section {
                    LabeledContent(L("shortcuts.profiles")) {
                        ProfileScopePicker(profileIDs: $binding.profileIDs, profiles: runtime.config.workspace.profiles)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("shortcuts.apps"))
                        AppListEditor(bundleIDs: $binding.appBundleIDs, emptyKey: "shortcuts.appsEmpty")
                    }
                } header: {
                    Text(L("shortcuts.scope"))
                } footer: {
                    Text(L("shortcuts.scopeFooter")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(L("common.delete"), role: .destructive, action: onDelete)
                Spacer()
                Button(L("common.cancel")) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(L("common.save")) { onDone(binding) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(binding.actions.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
    }
}

// MARK: - Conflicts

/// Builds the conflict report across Keystivo bindings and the system.
enum ConflictReport {
    static func make(runtime: KeystivoRuntime) -> [BindingConflict] {
        var bindings: [TriggerBinding] = []
        for binding in runtime.config.hotkeys where binding.isEnabled {
            guard let combo = binding.combo else { continue }
            let title = binding.name.isEmpty ? binding.actions.map { ActionRegistry.shared.title(for: $0) }.joined(separator: " → ") : binding.name
            bindings.append(TriggerBinding(id: binding.id.uuidString, trigger: .keyCombo(combo), title: title, origin: .keystivo,
                                           scope: binding.appBundleIDs.isEmpty ? nil : Set(binding.appBundleIDs)))
        }
        for workflow in runtime.config.automation.workflows where workflow.isEnabled {
            for combo in workflow.hotkeys {
                bindings.append(TriggerBinding(id: "workflow.\(workflow.id)", trigger: .keyCombo(combo), title: workflow.name, origin: .keystivo))
            }
        }
        for binding in runtime.config.gestures.bindings where binding.isEnabled {
            let title = binding.actions.map { ActionRegistry.shared.title(for: $0) }.joined(separator: " → ")
            let scope = binding.appBundleIDs.isEmpty ? nil : Set(binding.appBundleIDs)
            switch binding.trigger {
            case .trackpad(let gesture):
                bindings.append(TriggerBinding(id: binding.id.uuidString, trigger: .trackpad(gesture), title: title, origin: .keystivo, scope: scope))
            case .mouse(let gesture):
                bindings.append(TriggerBinding(id: binding.id.uuidString, trigger: .mouse(gesture), title: title, origin: .keystivo, scope: scope))
            }
        }
        bindings += SystemBindings.symbolicHotKeys()
        bindings += SystemBindings.commonAppShortcuts()
        bindings += SystemBindings.trackpadGestures()
        return ConflictDetector.detect(bindings)
    }
}

struct ConflictRow: View {
    let conflict: BindingConflict

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: conflict.severity == .error ? "exclamationmark.octagon.fill" : (conflict.severity == .warning ? "exclamationmark.triangle.fill" : "arrow.triangle.branch"))
                .foregroundStyle(conflict.severity == .error ? .red : (conflict.severity == .warning ? .orange : .blue))
            VStack(alignment: .leading, spacing: 2) {
                Text(triggerText).font(.callout.weight(.semibold))
                Text("\(conflict.first.title)  ⟷  \(conflict.second.title)").font(.caption).foregroundStyle(.secondary)
                Text(L("conflict.severity.\(severityKey)")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var severityKey: String {
        switch conflict.severity {
        case .error: "error"
        case .warning: "warning"
        case .override: "override"
        }
    }

    private var triggerText: String {
        switch conflict.first.trigger {
        case .keyCombo(let combo): combo.displayString
        case .trackpad(let gesture): gesture.displayString
        case .mouse(let gesture): "🖱 " + gesture.displayString
        }
    }
}
