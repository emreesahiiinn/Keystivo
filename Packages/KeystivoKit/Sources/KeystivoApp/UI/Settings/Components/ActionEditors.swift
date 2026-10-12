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

/// Menu listing every registered action, grouped by category.
struct ActionPickerMenu<Label: View>: View {
    var include: (ActionDescriptor) -> Bool = { _ in true }
    let onPick: (ActionDescriptor) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(ActionCategory.allCases) { category in
                let descriptors = ActionRegistry.shared.descriptors(in: category).filter { !$0.id.hasPrefix("dynamic.") && include($0) }
                if !descriptors.isEmpty {
                    Menu {
                        ForEach(descriptors) { descriptor in
                            Button { onPick(descriptor) } label: {
                                SwiftUI.Label(L(descriptor.titleKey), systemImage: descriptor.symbolName)
                            }
                        }
                    } label: {
                        SwiftUI.Label(L(category.titleKey), systemImage: category.symbolName)
                    }
                }
            }
        } label: {
            label()
        }
    }
}

/// Ordered list of actions run one after another ("komut zincirleri").
struct ActionChainEditor: View {
    @Binding var actions: [ActionInvocation]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, invocation in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 22)
                    ActionInvocationEditor(invocation: safeElement($actions, id: invocation.id, fallback: invocation))
                    Spacer(minLength: 0)
                    VStack(spacing: 2) {
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == actions.count - 1)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Button {
                        endEditing()
                        actions.removeAll { $0.id == invocation.id }
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(L("common.remove"))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            ActionPickerMenu(onPick: { actions.append($0.defaultInvocation()) }) {
                Label(L(actions.isEmpty ? "actions.add" : "actions.addAnother"), systemImage: "plus")
            }
            .fixedSize()
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard actions.indices.contains(index), actions.indices.contains(target) else { return }
        endEditing()
        actions.swapAt(index, target)
    }
}

/// Edits one action and its parameters.
struct ActionInvocationEditor: View {
    @Binding var invocation: ActionInvocation

    var body: some View {
        let descriptor = ActionRegistry.shared.descriptor(invocation.actionID)
        VStack(alignment: .leading, spacing: 6) {
            ActionPickerMenu(onPick: { picked in
                invocation = ActionInvocation(picked.id, arguments: picked.defaultInvocation().arguments, id: invocation.id)
            }) {
                Label(descriptor.map { L($0.titleKey) } ?? invocation.actionID, systemImage: descriptor?.symbolName ?? "questionmark.square.dashed")
            }
            .fixedSize()
            if let descriptor {
                ForEach(descriptor.parameters) { parameter in
                    ParameterField(parameter: parameter, value: Binding(
                        get: { invocation.arguments[parameter.key] ?? parameter.defaultValue },
                        set: { invocation.arguments[parameter.key] = $0 }
                    ))
                }
            } else {
                Text(L("actions.unavailable")).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// Renders the right control for a parameter kind.
struct ParameterField: View {
    let parameter: ParameterSpec
    @Binding var value: ActionValue?

    var body: some View {
        LabeledContent(L(parameter.titleKey)) {
            control
        }
        .font(.callout)
    }

    @ViewBuilder
    private var control: some View {
        switch parameter.kind {
        case .text, .url, .filePath:
            TextField("", text: stringBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        case .multilineText:
            TextEditor(text: stringBinding)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 60, maxHeight: 140)
                .frame(maxWidth: 360)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
        case .number(let min, let max, let step):
            HStack {
                Slider(value: doubleBinding(default: min), in: min...max, step: step)
                    .frame(maxWidth: 200)
                Text(Calculator_format(doubleBinding(default: min).wrappedValue))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        case .toggle:
            Toggle("", isOn: Binding(get: { value?.boolValue ?? false }, set: { value = .bool($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        case .choice(let options):
            Picker("", selection: stringBinding) {
                ForEach(options) { option in Text(L(option.titleKey)).tag(option.value) }
            }
            .labelsHidden()
            .fixedSize()
        case .dynamicChoice(let provider):
            let options = ActionRegistry.shared.options(for: provider)
            Picker("", selection: stringBinding) {
                Text(L("picker.choose")).tag("")
                ForEach(options) { option in Text(L(option.titleKey)).tag(option.value) }
            }
            .labelsHidden()
            .fixedSize()
        case .application:
            AppPickerButton(bundleID: stringBinding)
        case .keyCombo:
            KeyRecorder(combo: Binding(
                get: { if case .keyCombo(let combo)? = value { combo } else { nil } },
                set: { value = $0.map(ActionValue.keyCombo) }
            ), allowsUnmodified: true)
        }
    }

    private var stringBinding: Binding<String> {
        Binding(get: { value?.stringValue ?? "" }, set: { value = .string($0) })
    }

    private func doubleBinding(default fallback: Double) -> Binding<Double> {
        Binding(get: { value?.doubleValue ?? fallback }, set: { value = .number($0) })
    }

    private func Calculator_format(_ number: Double) -> String {
        // Values come from settings files too: never convert huge or infinite numbers to Int.
        guard number.isFinite, abs(number) < 1e15 else { return number.formatted() }
        return number.rounded() == number ? String(Int(number)) : String(format: "%.1f", number)
    }
}
