import AppKit
import KeystivoCore
import SwiftUI

/// Settings › Menu Bar: what the Keystivo panel shows, in which order, and its look.
struct ControlCenterSettingsSection: View {
    @Bindable var runtime: KeystivoRuntime

    private var settings: Binding<ControlCenterSettings> { $runtime.config.menuBar.controlCenter }

    var body: some View {
        Section {
            Toggle(L("general.menuBarIcon"), isOn: $runtime.config.general.showsMenuBarIcon)
            Picker(L("cc.settings.background"), selection: settings.background) {
                ForEach(PanelBackground.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent(L("action.menubar.controlCenter")) { ActionShortcutField(runtime: runtime, actionID: "menubar.controlCenter") }
            HStack {
                Spacer()
                Button(L("cc.settings.preview")) { runtime.controlCenter.show() }
                Button(L("cc.settings.reset")) { runtime.config.menuBar.controlCenter = ControlCenterSettings() }
                    .disabled(runtime.config.menuBar.controlCenter == ControlCenterSettings())
            }
            .controlSize(.small)
        } header: {
            Text(L("cc.settings.title"))
        } footer: {
            Text(L("cc.settings.footer")).font(.caption).foregroundStyle(.secondary)
        }
        Section(L("cc.settings.modules")) {
            ModuleOrderEditor(modules: settings.modules)
        }
        Section {
            ToggleChooser(toggles: settings.toggles)
        } header: {
            Text(L("cc.settings.toggles"))
        } footer: {
            Text(L("cc.settings.togglesFooter")).font(.caption).foregroundStyle(.secondary)
        }
        Section(L("cc.settings.actions")) {
            ActionIDListEditor(actions: settings.actions)
        }
        Section {
            Toggle(L("cc.settings.mixerItem"), isOn: $runtime.config.menuBar.showsMixerItem)
            LabeledContent(L("action.menubar.mixer")) { ActionShortcutField(runtime: runtime, actionID: "menubar.mixer") }
        } header: {
            Text(L("cc.mixerTitle"))
        } footer: {
            Text(L("cc.settings.mixerFooter")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Shown modules in order (with up/down), then the hidden ones.
private struct ModuleOrderEditor: View {
    @Binding var modules: [ControlCenterModule]

    var body: some View {
        let hidden = ControlCenterModule.allCases.filter { !modules.contains($0) }
        ForEach(Array(modules.enumerated()), id: \.element) { index, module in
            row(module, shown: true) {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help(L("cc.settings.moveUp"))
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == modules.count - 1)
                    .help(L("cc.settings.moveDown"))
            }
        }
        ForEach(hidden) { module in
            row(module, shown: false) { EmptyView() }
        }
    }

    private func row<Buttons: View>(_ module: ControlCenterModule, shown: Bool, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { shown }, set: { on in
                if on { modules.append(module) } else { modules.removeAll { $0 == module } }
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)
            Image(systemName: module.symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(L(module.titleKey)).foregroundStyle(shown ? .primary : .secondary)
            Spacer()
            buttons().buttonStyle(.borderless)
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard modules.indices.contains(target) else { return }
        modules.swapAt(index, target)
    }
}

/// Pick the round toggles; they keep a fixed, familiar order.
private struct ToggleChooser: View {
    @Binding var toggles: [ControlCenterToggle]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(ControlCenterToggle.allCases) { toggle in
                Toggle(isOn: Binding(get: { toggles.contains(toggle) }, set: { on in
                    if on {
                        toggles.append(toggle)
                        toggles.sort { ControlCenterToggle.allCases.firstIndex(of: $0)! < ControlCenterToggle.allCases.firstIndex(of: $1)! }
                    } else {
                        toggles.removeAll { $0 == toggle }
                    }
                })) {
                    Text(L(toggle.titleKey))
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.vertical, 2)
    }
}

/// An ordered list of action IDs (quick actions, shortcut widgets): any action that needs no input.
struct ActionIDListEditor: View {
    @Binding var actions: [String]

    var body: some View {
        ForEach(Array(actions.enumerated()), id: \.element) { index, id in
            let descriptor = ActionRegistry.shared.descriptors[id]
            HStack(spacing: 10) {
                Image(systemName: descriptor?.symbolName ?? "questionmark").frame(width: 18).foregroundStyle(.secondary)
                Text(descriptor.map { L($0.titleKey) } ?? id)
                Spacer()
                Group {
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                        .help(L("cc.settings.moveUp"))
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == actions.count - 1)
                        .help(L("cc.settings.moveDown"))
                    Button { actions.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .help(L("common.remove"))
                }
                .buttonStyle(.borderless)
            }
        }
        ActionPickerMenu(include: { $0.parameters.isEmpty && !actions.contains($0.id) }, onPick: { actions.append($0.id) }) {
            Label(L("cc.settings.addAction"), systemImage: "plus")
        }
        .fixedSize()
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard actions.indices.contains(target) else { return }
        actions.swapAt(index, target)
    }
}
