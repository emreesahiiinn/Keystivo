import AppKit
import Carbon.HIToolbox
import KeystivoCore
import KeystivoInput
import SwiftUI

/// Settings › Gestures. Devices first, then one readable line per gesture
/// ("⌥ 3-finger swipe ← → Left Half"); editing happens in a focused sheet,
/// and new gestures start from ready-made suggestions.
struct GesturesPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var editing: UUID?
    @State private var adding = false

    private var gestures: Binding<GestureSettings> { $runtime.config.gestures }

    var body: some View {
        Form {
            PageHeader(symbol: "hand.draw.fill", color: .mint, titleKey: "settings.page.gestures", subtitleKey: "gesturesSettings.subtitle")
            devices
            Section {
                if runtime.config.gestures.bindings.isEmpty {
                    Text(L("gestures.empty")).foregroundStyle(.secondary)
                }
                ForEach(runtime.config.gestures.bindings) { binding in
                    GestureSummaryRow(binding: safeElement($runtime.config.gestures.bindings, id: binding.id, fallback: binding), deviceOn: deviceOn(binding.trigger)) { editing = binding.id } onDelete: {
                        runtime.config.gestures.bindings.removeAll { $0.id == binding.id }
                    }
                }
                HStack {
                    Button { adding = true } label: { Label(L("gesturesSettings.add"), systemImage: "plus") }
                    Spacer()
                }
            } header: {
                Text(L("gesturesSettings.bindings"))
            } footer: {
                Text(L("gestures.listFooter")).font(.caption).foregroundStyle(.secondary)
            }
            let conflicts = ConflictReport.make(runtime: runtime).filter { conflict in
                if case .keyCombo = conflict.first.trigger { return false }
                return true
            }
            if !conflicts.isEmpty {
                Section(L("gesturesSettings.conflicts")) {
                    ForEach(conflicts) { ConflictRow(conflict: $0) }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let binding = runtime.config.gestures.bindings.first(where: { $0.id == editing }) {
                GestureEditorSheet(runtime: runtime, binding: safeElement($runtime.config.gestures.bindings, id: binding.id, fallback: binding)) {
                    endEditing()
                    editing = nil
                    runtime.config.gestures.bindings.removeAll { $0.id == binding.id }
                } onDone: {
                    endEditing()
                    editing = nil
                }
            }
        }
        .sheet(isPresented: $adding) {
            GestureSuggestionsSheet(existing: runtime.config.gestures.bindings) { binding in
                add(binding)
                adding = false
            } onCustom: { trigger in
                let binding = GestureBinding(trigger: trigger, actions: [])
                add(binding)
                adding = false
                editing = binding.id
            } onCancel: {
                adding = false
            }
        }
    }

    private var devices: some View {
        Section {
            DeviceRow(symbol: "rectangle.and.hand.point.up.left.filled", titleKey: "gesturesSettings.trackpad", helpKey: "gestures.trackpadHelp",
                      isOn: gestures.trackpadEnabled)
            if !TrackpadGestureEngine.shared.isAvailable {
                Label(L("gesturesSettings.trackpadUnavailable"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            DeviceRow(symbol: "computermouse.fill", titleKey: "gesturesSettings.mouse",
                      help: L("gestures.mouseHelp", L(runtime.config.gestures.mouseButton.titleKey)), isOn: gestures.mouseEnabled)
            if runtime.config.gestures.mouseEnabled {
                DisclosureGroup(L("gestures.mouseOptions")) {
                    Picker(L("gesturesSettings.button"), selection: gestures.mouseButton) {
                        ForEach(MouseGestureButton.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                    }
                    Toggle(L("gesturesSettings.trail"), isOn: gestures.showsTrail)
                    VStack(alignment: .leading) {
                        Text(L("gesturesSettings.excluded"))
                        AppListEditor(bundleIDs: gestures.mouseExcludedApps)
                    }
                }
            }
        } header: {
            Text(L("gestures.devices"))
        }
    }

    private func deviceOn(_ trigger: GestureTrigger) -> Bool {
        if case .trackpad = trigger { return runtime.config.gestures.trackpadEnabled }
        return runtime.config.gestures.mouseEnabled
    }

    private func add(_ binding: GestureBinding) {
        runtime.config.gestures.bindings.append(binding)
        if case .trackpad = binding.trigger { runtime.config.gestures.trackpadEnabled = true } else { runtime.config.gestures.mouseEnabled = true }
    }
}

/// A device on/off switch with a one-line explanation.
private struct DeviceRow: View {
    let symbol: String
    let titleKey: String
    var helpKey: String?
    var help: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(titleKey))
                    Text(help ?? helpKey.map { L($0) } ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Describing gestures

/// A small picture of a gesture: the device, its direction and finger count.
struct GestureBadge: View {
    let trigger: GestureTrigger
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay { glyph }
            .overlay(alignment: .bottomTrailing) { corner }
    }

    @ViewBuilder
    private var glyph: some View {
        switch trigger {
        case .trackpad(let gesture):
            Image(systemName: Self.symbol(for: gesture))
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(Color.accentColor)
        case .mouse(let gesture):
            Text(gesture.displayString.isEmpty ? "·" : gesture.displayString)
                .font(.system(size: gesture.directions.count > 2 ? size * 0.26 : size * 0.38, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .minimumScaleFactor(0.5)
                .padding(3)
        }
    }

    @ViewBuilder
    private var corner: some View {
        switch trigger {
        case .trackpad(let gesture) where gesture.kind != .tipTap:
            Text("\(gesture.fingers)")
                .font(.system(size: size * 0.28, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(size * 0.06)
        case .mouse:
            Image(systemName: "computermouse.fill")
                .font(.system(size: size * 0.24))
                .foregroundStyle(.secondary)
                .padding(size * 0.06)
        default:
            EmptyView()
        }
    }

    static func symbol(for gesture: TrackpadGesture) -> String {
        switch gesture.kind {
        case .swipe: "arrow.\(gesture.direction?.rawValue ?? "up")"
        case .tap: "hand.tap"
        case .doubleTap: "hand.tap.fill"
        case .tipTap: gesture.direction == .left ? "hand.point.left" : "hand.point.right"
        }
    }
}

extension GestureTrigger {
    /// "⌥ 3-finger swipe ←", "Draw ← → with the right button".
    @MainActor var sentence: String {
        switch self {
        case .trackpad(let gesture): gesture.displayString
        case .mouse(let gesture): L("gestures.mouseSentence", gesture.displayString.isEmpty ? "…" : gesture.displayString)
        }
    }
}

extension ActionInvocation {
    /// The action's title, with its key combination when it presses keys.
    @MainActor var summary: String {
        let title = ActionRegistry.shared.descriptors[actionID].map { L($0.titleKey) } ?? actionID
        if let combo = ActionArguments(arguments).combo("keys") { return "\(title) \(combo.displayString)" }
        return title
    }
}

/// One gesture in the list: picture, what to do, what it does, where.
private struct GestureSummaryRow: View {
    @Binding var binding: GestureBinding
    let deviceOn: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $binding.isEnabled).labelsHidden().toggleStyle(.checkbox)
                .help(L("gestures.enabledHelp"))
            GestureBadge(trigger: binding.trigger)
                .opacity(binding.isEnabled && deviceOn ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 3) {
                Text(binding.trigger.sentence)
                    .foregroundStyle(binding.isEnabled && deviceOn ? .primary : .secondary)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold))
                    if binding.actions.isEmpty {
                        Text(L("gestures.noAction")).foregroundStyle(.orange)
                    } else {
                        Text(binding.actions.map(\.summary).joined(separator: " → ")).lineLimit(1)
                    }
                    if !binding.appBundleIDs.isEmpty {
                        Text("·")
                        Text(L("gestures.onlyApps", binding.appBundleIDs.count)).lineLimit(1)
                    }
                    if !deviceOn {
                        Text("·")
                        Text(L("gestures.deviceOff")).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L("gestures.edit"), action: onEdit)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button(L("gestures.edit"), action: onEdit)
            Button(L("common.delete"), role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Editor

/// Edits one gesture in three steps: the gesture, what it does, where it works.
private struct GestureEditorSheet: View {
    let runtime: KeystivoRuntime
    @Binding var binding: GestureBinding
    let onDelete: () -> Void
    let onDone: () -> Void
    @State private var isRecording = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                GestureBadge(trigger: binding.trigger, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(binding.trigger.sentence).font(.headline)
                    Text(binding.actions.isEmpty ? L("gestures.noAction") : binding.actions.map(\.summary).joined(separator: " → "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Section(L("gestures.step.gesture")) {
                    Picker(L("gestures.device"), selection: deviceBinding) {
                        Text(L("gesturesSettings.trackpad")).tag(false)
                        Text(L("gesturesSettings.mouse")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    triggerEditor
                    HStack {
                        Button(isRecording ? L("gesturesSettings.recording") : L("gestures.recordInstead")) { toggleRecording() }
                            .tint(isRecording ? .red : nil)
                        if isRecording {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                    }
                }
                Section(L("gestures.step.action")) {
                    ActionChainEditor(actions: $binding.actions)
                }
                Section(L("gestures.step.where")) {
                    Picker(L("gestures.where"), selection: Binding(get: { binding.appBundleIDs.isEmpty ? 0 : 1 }, set: { value in
                        if value == 0 { binding.appBundleIDs = [] } else if binding.appBundleIDs.isEmpty { binding.appBundleIDs = [] }
                        scopeIsApps = value == 1
                    })) {
                        Text(L("gesturesSettings.everywhere")).tag(0)
                        Text(L("gestures.onlySomeApps")).tag(1)
                    }
                    .pickerStyle(.radioGroup)
                    if scopeIsApps || !binding.appBundleIDs.isEmpty {
                        AppListEditor(bundleIDs: $binding.appBundleIDs)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(L("common.delete"), role: .destructive, action: onDelete)
                Spacer()
                Button(L("gestures.done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onDisappear { if isRecording { runtime.gestures.stopRecording() } }
    }

    @State private var scopeIsApps = false

    private var deviceBinding: Binding<Bool> {
        Binding(get: {
            if case .mouse = binding.trigger { return true }
            return false
        }, set: { isMouse in
            if isMouse {
                binding.trigger = .mouse(MouseGesture(button: runtime.config.gestures.mouseButton, strokes: "L"))
                runtime.config.gestures.mouseEnabled = true
            } else {
                binding.trigger = .trackpad(TrackpadGesture(kind: .swipe, fingers: 3, direction: .up, modifiers: .option))
                runtime.config.gestures.trackpadEnabled = true
            }
        })
    }

    @ViewBuilder
    private var triggerEditor: some View {
        switch binding.trigger {
        case .trackpad(let gesture):
            Picker(L("gestures.kind"), selection: Binding(get: { gesture.kind }, set: { kind in
                var updated = gesture
                updated.kind = kind
                if kind == .swipe, updated.direction == nil { updated.direction = .up }
                if kind == .tipTap, updated.direction != .left, updated.direction != .right { updated.direction = .right }
                binding.trigger = .trackpad(updated)
            })) {
                ForEach(TrackpadGesture.Kind.allCases, id: \.self) { Text(L("gesture.kind.\($0.rawValue)")).tag($0) }
            }
            .pickerStyle(.segmented)
            if gesture.kind != .tipTap {
                Picker(L("gestures.fingers"), selection: Binding(get: { gesture.fingers }, set: { var g = gesture; g.fingers = $0; binding.trigger = .trackpad(g) })) {
                    ForEach(2...5, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if gesture.kind == .swipe || gesture.kind == .tipTap {
                Picker(L("gestures.direction"), selection: Binding(get: { gesture.direction ?? .up }, set: { var g = gesture; g.direction = $0; binding.trigger = .trackpad(g) })) {
                    ForEach(gesture.kind == .tipTap ? [GestureDirection.left, .right] : GestureDirection.allCases, id: \.self) {
                        Text($0.symbol).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }
            LabeledContent(L("gestures.holdKeys")) {
                ModifierPicker(modifiers: Binding(get: { gesture.modifiers }, set: { var g = gesture; g.modifiers = $0; binding.trigger = .trackpad(g) }))
            }
            if gesture.kind == .swipe, gesture.fingers == 2, gesture.modifiers.isEmpty {
                Label(L("gestures.twoFingerWarning"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        case .mouse(let gesture):
            LabeledContent(L("gestures.strokes")) {
                HStack(spacing: 4) {
                    ForEach([GestureDirection.left, .up, .down, .right], id: \.self) { direction in
                        Button(direction.symbol) {
                            guard gesture.strokes.count < 6 else { return }
                            binding.trigger = .mouse(MouseGesture(button: gesture.button, strokes: gesture.strokes + String(direction.letter)))
                        }
                        .help(L("gestures.addStroke"))
                    }
                    Button { binding.trigger = .mouse(MouseGesture(button: gesture.button, strokes: String(gesture.strokes.dropLast()))) } label: {
                        Image(systemName: "delete.left")
                    }
                    .disabled(gesture.strokes.isEmpty)
                    .help(L("gestures.removeStroke"))
                }
            }
            Text(L("gestures.mouseHelp", L(runtime.config.gestures.mouseButton.titleKey))).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func toggleRecording() {
        if isRecording {
            runtime.gestures.stopRecording()
            isRecording = false
            return
        }
        isRecording = true
        runtime.gestures.startRecording { trigger in
            binding.trigger = trigger
            runtime.gestures.stopRecording()
            isRecording = false
        }
    }
}

/// ⌃ ⌥ ⇧ ⌘ as toggle buttons.
private struct ModifierPicker: View {
    @Binding var modifiers: KeyModifiers

    var body: some View {
        HStack(spacing: 3) {
            ForEach([(KeyModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")], id: \.1) { modifier, symbol in
                Toggle(symbol, isOn: Binding(get: { modifiers.contains(modifier) }, set: { if $0 { modifiers.insert(modifier) } else { modifiers.remove(modifier) } }))
                    .toggleStyle(.button)
            }
        }
    }
}

// MARK: - Suggestions

/// Ready-made gestures to start from (only ones not set up yet).
private struct GestureSuggestionsSheet: View {
    let existing: [GestureBinding]
    let onAdd: (GestureBinding) -> Void
    let onCustom: (GestureTrigger) -> Void
    let onCancel: () -> Void

    private var suggestions: [GestureBinding] {
        let swipe = { (direction: GestureDirection) in GestureTrigger.trackpad(TrackpadGesture(kind: .swipe, fingers: 3, direction: direction, modifiers: .option)) }
        let all: [GestureBinding] = [
            GestureBinding(trigger: .trackpad(TrackpadGesture(kind: .tap, fingers: 4)), actions: [ActionInvocation("launcher.show")]),
            GestureBinding(trigger: swipe(.left), actions: [ActionInvocation("windows.snap.leftHalf")]),
            GestureBinding(trigger: swipe(.right), actions: [ActionInvocation("windows.snap.rightHalf")]),
            GestureBinding(trigger: swipe(.up), actions: [ActionInvocation("windows.snap.maximize")]),
            GestureBinding(trigger: swipe(.down), actions: [ActionInvocation("windows.snap.center")]),
            GestureBinding(trigger: .trackpad(TrackpadGesture(kind: .tap, fingers: 5)), actions: [ActionInvocation("clipboard.history")]),
            GestureBinding(trigger: .trackpad(TrackpadGesture(kind: .tipTap, fingers: 2, direction: .left)), actions: [ActionInvocation("system.pressKeys", arguments: ["keys": .keyCombo(KeyCombo(kVK_ANSI_LeftBracket, .command))])]),
            GestureBinding(trigger: .trackpad(TrackpadGesture(kind: .tipTap, fingers: 2, direction: .right)), actions: [ActionInvocation("system.pressKeys", arguments: ["keys": .keyCombo(KeyCombo(kVK_ANSI_RightBracket, .command))])]),
            GestureBinding(trigger: .mouse(MouseGesture(strokes: "L")), actions: [ActionInvocation("system.pressKeys", arguments: ["keys": .keyCombo(KeyCombo(kVK_ANSI_LeftBracket, .command))])]),
            GestureBinding(trigger: .mouse(MouseGesture(strokes: "R")), actions: [ActionInvocation("system.pressKeys", arguments: ["keys": .keyCombo(KeyCombo(kVK_ANSI_RightBracket, .command))])]),
            GestureBinding(trigger: .mouse(MouseGesture(strokes: "D")), actions: [ActionInvocation("windows.minimize")]),
            GestureBinding(trigger: .mouse(MouseGesture(strokes: "DR")), actions: [ActionInvocation("windows.close")]),
        ]
        return all.filter { suggestion in !existing.contains { $0.trigger.matches(suggestion.trigger) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("gestures.suggestionsTitle")).font(.title3.weight(.semibold))
                Text(L("gestures.suggestionsSubtitle")).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    if suggestions.isEmpty {
                        Text(L("gestures.allAdded")).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(suggestions) { suggestion in
                        SuggestionRow(binding: suggestion) { onAdd(suggestion) }
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                Menu(L("gestures.custom")) {
                    Button(L("gesturesSettings.addTrackpad")) { onCustom(.trackpad(TrackpadGesture(kind: .swipe, fingers: 3, direction: .up, modifiers: .option))) }
                    Button(L("gesturesSettings.addMouse")) { onCustom(.mouse(MouseGesture(strokes: "U"))) }
                }
                .fixedSize()
                Spacer()
                Button(L("common.cancel"), action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }
}

private struct SuggestionRow: View {
    let binding: GestureBinding
    let onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            GestureBadge(trigger: binding.trigger)
            VStack(alignment: .leading, spacing: 2) {
                Text(binding.trigger.sentence)
                Text(binding.actions.map(\.summary).joined(separator: " → ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("common.add"), action: onAdd)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0.035)))
        .onHover { hovering = $0 }
    }
}
