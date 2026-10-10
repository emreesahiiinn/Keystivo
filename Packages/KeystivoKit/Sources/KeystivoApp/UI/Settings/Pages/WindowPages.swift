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

// MARK: - Switcher

struct SwitcherPage: View {
    @Bindable var runtime: KeystivoRuntime

    var body: some View {
        Form {
            PageHeader(symbol: "rectangle.on.rectangle", color: .blue, titleKey: "settings.page.switcher", subtitleKey: "switcherSettings.subtitle")
            Section {
                Toggle(isOn: $runtime.config.switcher.replacesCommandTab) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("switcherSettings.replaceCmdTab"))
                        Text(L("switcherSettings.replaceCmdTabFooter")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if runtime.config.switcher.replacesCommandTab {
                    if PermissionCenter.shared.isGranted(.accessibility) {
                        Label(L("switcherSettings.statusActive"), systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    } else {
                        HStack {
                            Label(L("switcherSettings.statusInactive"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                            Spacer()
                            Button(L("permissions.grant")) { PermissionCenter.shared.request(.accessibility) }
                        }
                        Text(L("switcherSettings.needsAccessibility")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(L("action.windows.switcher")) { ActionShortcutField(runtime: runtime, actionID: "windows.switcher") }
                LabeledContent(L("action.windows.switcherApp")) { ActionShortcutField(runtime: runtime, actionID: "windows.switcherApp") }
                LabeledContent(L("action.windows.previous")) { ActionShortcutField(runtime: runtime, actionID: "windows.previous") }
            }
            Section(L("switcherSettings.appearance")) {
                Toggle(L("switcherSettings.thumbnails"), isOn: $runtime.config.switcher.showsThumbnails)
                if runtime.config.switcher.showsThumbnails, !ThumbnailService.shared.isAvailable {
                    HStack {
                        Label(L("switcherSettings.needsScreenRecording"), systemImage: "rectangle.dashed.badge.record").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(L("permissions.grant")) { PermissionCenter.shared.request(.screenRecording) }
                    }
                }
                LabeledContent(L("switcherSettings.thumbnailSize")) {
                    Slider(value: $runtime.config.switcher.thumbnailWidth, in: 160...360, step: 20).frame(width: 220)
                }
                Toggle(L("switcherSettings.groupByApp"), isOn: $runtime.config.switcher.groupsByApp)
            }
            Section(L("switcherSettings.include")) {
                Toggle(L("switcherSettings.minimized"), isOn: $runtime.config.switcher.includesMinimized)
                Toggle(L("switcherSettings.hidden"), isOn: $runtime.config.switcher.includesHiddenApps)
                Toggle(L("switcherSettings.otherSpaces"), isOn: $runtime.config.switcher.includesOtherSpaces)
            }
            Section(L("switcherSettings.keys")) {
                Text(L("switcherSettings.keysHelp")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Window management

struct WindowsPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var newLayoutName = ""
    @State private var addingRule = false

    private let snapGroups: [(String, [SnapPosition])] = [
        ("windowsSettings.halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("windowsSettings.thirds", [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds]),
        ("windowsSettings.quarters", [.topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter]),
        ("windowsSettings.other", [.maximize, .almostMaximize, .maximizeHeight, .center, .reasonableSize]),
    ]

    var body: some View {
        Form {
            PageHeader(symbol: "macwindow.on.rectangle", color: .blue, titleKey: "settings.page.windows", subtitleKey: "windowsSettings.subtitle")
            Section {
                Toggle(L("dragSnap.enabled"), isOn: $runtime.config.windows.dragSnap.isEnabled)
                Toggle(L("dragSnap.topMaximizes"), isOn: $runtime.config.windows.dragSnap.topEdgeMaximizes)
                Toggle(L("dragSnap.bottomThirds"), isOn: $runtime.config.windows.dragSnap.bottomEdgeThirds)
                Toggle(L("dragSnap.commandBypass"), isOn: $runtime.config.windows.dragSnap.commandBypasses)
                VStack(alignment: .leading) {
                    Text(L("dragSnap.excluded"))
                    AppListEditor(bundleIDs: $runtime.config.windows.dragSnap.excludedApps)
                }
            } header: {
                Text(L("dragSnap.title"))
            } footer: {
                Text(L("dragSnap.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("windowsSettings.behavior")) {
                LabeledContent(L("windowsSettings.gap", Int(runtime.config.windows.gap))) {
                    Slider(value: $runtime.config.windows.gap, in: 0...40, step: 2).frame(width: 220)
                }
                Toggle(L("windowsSettings.cycle"), isOn: $runtime.config.windows.cyclesOnRepeat)
                Toggle(L("windowsSettings.preserveSnap"), isOn: $runtime.config.windows.preservesSnapAcrossDisplays)
            }
            ForEach(snapGroups, id: \.0) { group in
                Section(L(group.0)) {
                    ForEach(group.1) { position in
                        LabeledContent {
                            ActionShortcutField(runtime: runtime, actionID: "windows.snap.\(position.rawValue)")
                        } label: {
                            Label(L(position.titleKey), systemImage: position.symbolName)
                        }
                    }
                }
            }
            Section(L("windowsSettings.displays")) {
                ForEach(DisplayTarget.allCases, id: \.self) { target in
                    LabeledContent(L("action.windows.display.\(target.rawValue)")) {
                        ActionShortcutField(runtime: runtime, actionID: "windows.display.\(target.rawValue)")
                    }
                }
            }
            Section {
                HStack {
                    TextField(L("windowsSettings.layoutName"), text: $newLayoutName)
                    Button(L("windowsSettings.saveLayout")) {
                        let name = newLayoutName
                        newLayoutName = ""
                        ActionRegistry.shared.run(ActionInvocation("windows.saveLayout", arguments: ["name": .string(name)]), source: .menuBar)
                    }
                }
                ForEach($runtime.config.windows.layouts) { $layout in
                    LayoutRow(layout: $layout) {
                        runtime.config.windows.layouts.removeAll { $0.id == layout.id }
                    }
                }
            } header: {
                Text(L("windowsSettings.layouts"))
            } footer: {
                Text(L("windowsSettings.layoutsFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($runtime.config.windows.rules) { $rule in
                    RuleRow(rule: $rule) { runtime.config.windows.rules.removeAll { $0.id == rule.id } }
                }
                HStack {
                    Button(L("windowsSettings.addRule")) { addingRule = true }
                        .popover(isPresented: $addingRule) {
                            AppPickerList { bundleID in
                                runtime.config.windows.rules.append(AppWindowRule(bundleID: bundleID, placement: .snap(.center)))
                                addingRule = false
                            }
                        }
                    Text(L("windowsSettings.ruleTip")).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(L("windowsSettings.defaultPositions"))
            }
            Section(L("windowsSettings.arrange")) {
                HStack {
                    ForEach(ArrangementStyle.allCases) { style in
                        Button(L(style.titleKey)) {
                            ActionRegistry.shared.run(ActionInvocation("windows.arrange.\(style.rawValue)"), source: .menuBar)
                        }
                    }
                }
                LabeledContent(L("action.windows.gatherToScreen")) { ActionShortcutField(runtime: runtime, actionID: "windows.gatherToScreen") }
                LabeledContent(L("action.windows.undo")) { ActionShortcutField(runtime: runtime, actionID: "windows.undo") }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LayoutRow: View {
    @Binding var layout: WindowLayout
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "rectangle.3.group")
                TextField("", text: $layout.name).textFieldStyle(.plain).font(.callout.weight(.medium))
                Spacer()
                Text(L("windowsSettings.layoutInfo", layout.entries.count, layout.displayCount)).font(.caption).foregroundStyle(.secondary)
                Button(L("windowsSettings.restore")) {
                    let captured = layout
                    Task { await LayoutManager.shared.restore(captured) }
                }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                Toggle(L("windowsSettings.autoRestore"), isOn: $layout.restoresOnDisplayChange)
                Toggle(L("windowsSettings.launchMissing"), isOn: $layout.launchesMissingApps)
                if layout.displaySignature == LayoutManager.displaySignature() {
                    Badge(text: L("windowsSettings.currentDisplays"), color: .green)
                }
            }
            .font(.caption)
            .toggleStyle(.checkbox)
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: AppWindowRule
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: $rule.isEnabled).labelsHidden().toggleStyle(.checkbox)
            AppIconView(bundleID: rule.bundleID, size: 18)
            Text(AppDisplayName.name(forBundleID: rule.bundleID) ?? rule.bundleID).lineLimit(1)
            Spacer()
            Picker("", selection: Binding(
                get: { if case .snap(let position) = rule.placement { position.rawValue } else { "custom" } },
                set: { value in if let position = SnapPosition(rawValue: value) { rule.placement = .snap(position) } }
            )) {
                ForEach(SnapPosition.allCases) { Text(L($0.titleKey)).tag($0.rawValue) }
                if case .relative = rule.placement { Text(L("windowsSettings.savedPosition")).tag("custom") }
            }
            .labelsHidden()
            .frame(width: 170)
            Picker("", selection: $rule.display) {
                ForEach(DisplayPreference.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            Toggle(L("windowsSettings.everyWindow"), isOn: $rule.everyNewWindow).toggleStyle(.checkbox).font(.caption)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }
}

// MARK: - Dock & launcher bar

struct DockPage: View {
    @Bindable var runtime: KeystivoRuntime

    var body: some View {
        Form {
            PageHeader(symbol: "dock.rectangle", color: .indigo, titleKey: "settings.page.dock", subtitleKey: "dockSettings.subtitle")
            Section(L("dockSettings.previews")) {
                Toggle(L("dockSettings.previewsEnabled"), isOn: $runtime.config.dock.previewsEnabled)
                LabeledContent(L("dockSettings.previewSize")) {
                    Slider(value: $runtime.config.dock.previewWidth, in: 140...360, step: 20).frame(width: 220)
                }
                Text(L("dockSettings.previewsFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("dockSettings.launcherBar")) {
                Toggle(L("dockSettings.barEnabled"), isOn: $runtime.config.dock.launcherBar.isEnabled)
                Picker(L("dockSettings.edge"), selection: $runtime.config.dock.launcherBar.edge) {
                    ForEach(ScreenEdge.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("dockSettings.autoHide"), isOn: $runtime.config.dock.launcherBar.autoHides)
                Toggle(L("dockSettings.running"), isOn: $runtime.config.dock.launcherBar.showsRunningApps)
                LabeledContent(L("dockSettings.iconSize")) {
                    Slider(value: $runtime.config.dock.launcherBar.iconSize, in: 28...72, step: 4).frame(width: 220)
                }
            }
            Section(L("dockSettings.pinned")) {
                AppListEditor(bundleIDs: $runtime.config.dock.launcherBar.pinnedApps)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Workspaces

struct WorkspacesPage: View {
    @Bindable var runtime: KeystivoRuntime

    var body: some View {
        let focus = FocusController.shared
        Form {
            PageHeader(symbol: "rectangle.3.group.fill", color: .purple, titleKey: "settings.page.workspaces", subtitleKey: "workspaces.subtitle")
            Section {
                HStack {
                    if focus.isActive {
                        Label(L("workspaces.focusActive"), systemImage: "moon.fill").foregroundStyle(.indigo)
                        if let endsAt = focus.endsAt {
                            Text(timerInterval: Date.now...endsAt, countsDown: true).monospacedDigit()
                        }
                        Spacer()
                        Button(L("action.focus.stop")) { focus.stop() }
                    } else {
                        Button(L("action.focus.start")) { focus.start() }
                        Spacer()
                    }
                }
                LabeledContent(L("action.focus.toggle")) { ActionShortcutField(runtime: runtime, actionID: "focus.toggle") }
                Stepper(L("workspaces.defaultMinutes", runtime.config.workspace.focus.defaultMinutes), value: $runtime.config.workspace.focus.defaultMinutes, in: 0...240, step: 5)
                Toggle(L("workspaces.hideDistracting"), isOn: $runtime.config.workspace.focus.hidesDistractingApps)
                Toggle(L("workspaces.quitInstead"), isOn: $runtime.config.workspace.focus.quitsInsteadOfHiding)
                Toggle(L("workspaces.blockLaunching"), isOn: $runtime.config.workspace.focus.blocksLaunching)
                Toggle(L("workspaces.hideOthers"), isOn: $runtime.config.workspace.focus.hidesOtherApps)
                Toggle(L("workspaces.dim"), isOn: $runtime.config.workspace.focus.dimsBackground)
                if runtime.config.workspace.focus.dimsBackground {
                    LabeledContent(L("workspaces.dimOpacity")) {
                        Slider(value: $runtime.config.workspace.focus.dimOpacity, in: 0.15...0.85).frame(width: 220)
                    }
                }
                TextField(L("workspaces.startShortcut"), text: $runtime.config.workspace.focus.startShortcut, prompt: Text(L("workspaces.shortcutPrompt")))
                TextField(L("workspaces.endShortcut"), text: $runtime.config.workspace.focus.endShortcut, prompt: Text(L("workspaces.shortcutPrompt")))
            } header: {
                Text(L("workspaces.focus"))
            } footer: {
                Text(L("workspaces.focusFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("workspaces.distractingApps")) {
                AppListEditor(bundleIDs: $runtime.config.workspace.focus.distractingApps)
            }
            Section {
                ForEach($runtime.config.workspace.appGroups) { $group in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            SymbolPicker(symbol: $group.symbolName)
                            TextField(L("workspaces.groupName"), text: $group.name).textFieldStyle(.roundedBorder)
                            Button(L("workspaces.openGroup")) {
                                ActionRegistry.shared.run(ActionInvocation("apps.group.launch", arguments: ["group": .string(group.id.uuidString)]), source: .menuBar)
                            }
                            Button(role: .destructive) {
                                runtime.config.workspace.appGroups.removeAll { $0.id == group.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                        AppListEditor(bundleIDs: $group.bundleIDs)
                    }
                    .padding(.vertical, 4)
                }
                Button(L("workspaces.addGroup")) {
                    runtime.config.workspace.appGroups.append(AppGroup(name: L("workspaces.newGroup"), bundleIDs: []))
                }
            } header: {
                Text(L("workspaces.appGroups"))
            } footer: {
                Text(L("workspaces.appGroupsFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("workspaces.history")) {
                WindowHistoryList()
            }
        }
        .formStyle(.grouped)
    }
}

/// Recent focus and moves ("pencere geçmişi" / "pencere odak geçmişi").
private struct WindowHistoryList: View {
    var body: some View {
        let records = FocusHistory.shared.records.prefix(12)
        let moves = WindowManager.shared.moves.prefix(6)
        VStack(alignment: .leading, spacing: 6) {
            if records.isEmpty { Text(L("workspaces.historyEmpty")).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(records)) { record in
                HStack {
                    AppIconView(bundleID: record.bundleID, size: 16)
                    Text(record.title.isEmpty ? record.appName : record.title).lineLimit(1)
                    Spacer()
                    Text(record.lastFocused, style: .relative).font(.caption).foregroundStyle(.secondary)
                    Button(L("workspaces.focusWindow")) {
                        let element = AXElement.application(pid: record.pid).windows.first { $0.windowID == record.windowID }
                        WindowFocus.focus(window: element ?? AXElement.application(pid: record.pid), windowID: record.windowID, pid: record.pid)
                    }
                    .buttonStyle(.borderless)
                }
                .font(.callout)
            }
            if !moves.isEmpty {
                Divider()
                ForEach(Array(moves)) { move in
                    HStack {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").foregroundStyle(.secondary)
                        Text("\(move.appName) — \(move.title)").lineLimit(1)
                        Spacer()
                        Text(move.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                Button(L("action.windows.undo")) { WindowManager.shared.undoLastMove() }
            }
        }
    }
}
