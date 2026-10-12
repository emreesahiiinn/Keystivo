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
import UniformTypeIdentifiers

struct AutomationPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var selection: UUID?
    @State private var showsLibrary = false
    @State private var showsHistory = false
    @State private var importError: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(runtime.config.automation.workflows) { workflow in
                        HStack(spacing: 8) {
                            Image(systemName: workflow.symbolName).foregroundStyle(workflow.isEnabled ? .yellow : .secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(workflow.name).lineLimit(1)
                                Text(workflow.triggers.map { L($0.titleKey) }.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if AutomationEngine.shared.runningWorkflowIDs.contains(workflow.id) {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .opacity(workflow.isEnabled ? 1 : 0.55)
                        .tag(workflow.id)
                    }
                    .onMove { runtime.config.automation.workflows.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 10) {
                    Menu {
                        Button(L("automation.newBlank")) { add(Workflow(name: L("automation.untitled"), triggers: [.manual], steps: [])) }
                        Button(L("automation.fromLibrary")) { showsLibrary = true }
                        Button(L("automation.import")) { importWorkflows() }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button {
                        runtime.config.automation.workflows.removeAll { $0.id == selection }
                        selection = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                    Button { showsHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .help(L("automation.history"))
                    Toggle("", isOn: $runtime.config.automation.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help(L("automation.masterToggle"))
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 230, maxWidth: 300)

            Group {
                if let index = runtime.config.automation.workflows.firstIndex(where: { $0.id == selection }) {
                    WorkflowEditor(runtime: runtime, workflow: $runtime.config.automation.workflows[index])
                } else {
                    Form {
                        PageHeader(symbol: "bolt.fill", color: .yellow, titleKey: "settings.page.automation", subtitleKey: "automation.subtitle")
                        Section {
                            Text(L("automation.intro")).font(.callout).foregroundStyle(.secondary)
                            Button(L("automation.fromLibrary")) { showsLibrary = true }
                        }
                        if let importError { Section { Text(importError).foregroundStyle(.red) } }
                    }
                    .formStyle(.grouped)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showsLibrary) {
            LibrarySheet { workflow in
                add(workflow)
                showsLibrary = false
            } onCancel: { showsLibrary = false }
        }
        .sheet(isPresented: $showsHistory) { RunHistorySheet { showsHistory = false } }
    }

    private func add(_ workflow: Workflow) {
        runtime.config.automation.workflows.append(workflow)
        selection = workflow.id
    }

    private func importWorkflows() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: AutomationLibrary.fileExtension) ?? .json, .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls {
                let imported = try AutomationLibrary.import(try Data(contentsOf: url))
                runtime.config.automation.workflows.append(contentsOf: imported)
                selection = imported.first?.id ?? selection
            }
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Workflow editor

struct WorkflowEditor: View {
    let runtime: KeystivoRuntime
    @Binding var workflow: Workflow

    var body: some View {
        Form {
            Section {
                HStack {
                    SymbolPicker(symbol: $workflow.symbolName)
                    TextField(L("automation.name"), text: $workflow.name).textFieldStyle(.roundedBorder)
                    Toggle(L("automation.enabled"), isOn: $workflow.isEnabled).toggleStyle(.switch)
                }
                TextField(L("automation.notes"), text: $workflow.notes, axis: .vertical).lineLimit(1...3)
                HStack {
                    Button {
                        AutomationEngine.shared.run(workflow, trigger: "settings")
                    } label: { Label(L("automation.runNow"), systemImage: "play.fill") }
                    Button(L("automation.export")) { export() }
                    Spacer()
                    if let run = AutomationEngine.shared.runs.first(where: { $0.workflowID == workflow.id }) {
                        RunStatusBadge(run: run)
                    }
                }
            }
            Section(L("automation.triggers")) {
                ForEach($workflow.triggers.indices, id: \.self) { index in
                    HStack(alignment: .top) {
                        TriggerEditor(trigger: safeElement($workflow.triggers, index))
                        Spacer()
                        Button { if workflow.triggers.indices.contains(index) { workflow.triggers.remove(at: index) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu {
                    ForEach(Array(TriggerSpec.templates.enumerated()), id: \.offset) { _, template in
                        Button { workflow.triggers.append(template) } label: { Label(L(template.titleKey), systemImage: template.symbolName) }
                    }
                } label: { Label(L("automation.addTrigger"), systemImage: "plus") }
                .fixedSize()
            }
            Section {
                if workflow.condition != nil {
                    ConditionGroupEditor(condition: Binding(get: { workflow.condition ?? .all([]) }, set: { workflow.condition = $0 }), runtime: runtime)
                    Button(L("automation.removeConditions"), role: .destructive) { workflow.condition = nil }
                } else {
                    Button(L("automation.addConditions")) { workflow.condition = .all([]) }
                }
            } header: {
                Text(L("automation.conditions"))
            } footer: {
                Text(L("automation.conditionsFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("automation.steps")) {
                StepListEditor(steps: $workflow.steps, runtime: runtime, depth: 0)
            }
            Section(L("automation.options")) {
                LabeledContent(L("shortcuts.profiles")) {
                    ProfileScopePicker(profileIDs: $workflow.profileIDs, profiles: runtime.config.workspace.profiles)
                }
                Toggle(L("automation.showsInLauncher"), isOn: $workflow.showsInLauncher)
                Toggle(L("automation.preventsOverlap"), isOn: $workflow.preventsOverlap)
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(workflow.name).\(AutomationLibrary.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? AutomationLibrary.export([workflow]) else { return }
        try? data.write(to: url)
    }
}

struct RunStatusBadge: View {
    let run: WorkflowRun

    var body: some View {
        let (text, color): (String, Color) = switch run.status {
        case .running: (L("automation.status.running"), .blue)
        case .succeeded: (L("automation.status.succeeded"), .green)
        case .failed: (L("automation.status.failed"), .red)
        case .cancelled: (L("automation.status.cancelled"), .gray)
        case .skipped: (L("automation.status.skipped"), .orange)
        }
        Badge(text: text, color: color).help(run.message ?? run.started.formatted())
    }
}

// MARK: - Triggers

struct TriggerEditor: View {
    @Binding var trigger: TriggerSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L(trigger.titleKey), systemImage: trigger.symbolName).font(.callout.weight(.medium))
            switch trigger {
            case .appLaunched(let id):
                AppPickerButton(bundleID: Binding(get: { id }, set: { trigger = .appLaunched(bundleID: $0) }), placeholderKey: "automation.anyApp")
            case .appQuit(let id):
                AppPickerButton(bundleID: Binding(get: { id }, set: { trigger = .appQuit(bundleID: $0) }), placeholderKey: "automation.anyApp")
            case .appActivated(let id):
                AppPickerButton(bundleID: Binding(get: { id }, set: { trigger = .appActivated(bundleID: $0) }), placeholderKey: "automation.anyApp")
            case .appDeactivated(let id):
                AppPickerButton(bundleID: Binding(get: { id }, set: { trigger = .appDeactivated(bundleID: $0) }), placeholderKey: "automation.anyApp")
            case .hotkey(let combo):
                KeyRecorder(combo: Binding(get: { combo.isUnset ? nil : combo }, set: { if let new = $0 { trigger = .hotkey(new) } }))
            case .schedule(let hour, let minute, let weekdays):
                HStack {
                    DatePicker("", selection: Binding(
                        get: { Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now },
                        set: { date in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                            trigger = .schedule(hour: parts.hour ?? 0, minute: parts.minute ?? 0, weekdays: weekdays)
                        }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    WeekdayPicker(weekdays: Binding(get: { weekdays }, set: { trigger = .schedule(hour: hour, minute: minute, weekdays: $0) }))
                }
            case .interval(let minutes):
                Stepper(L("automation.everyMinutes", minutes), value: Binding(get: { minutes }, set: { trigger = .interval(minutes: max(1, $0)) }), in: 1...1440)
            case .powerSourceChanged(let source):
                Picker("", selection: Binding(get: { source }, set: { trigger = .powerSourceChanged(to: $0) })) {
                    ForEach(PowerSourceKind.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                .labelsHidden().fixedSize()
            case .batteryBelow(let percent):
                Stepper(L("automation.percent", percent), value: Binding(get: { percent }, set: { trigger = .batteryBelow(percent: $0) }), in: 5...95, step: 5)
            case .inputDeviceConnected(let match):
                TextField(L("automation.deviceMatch"), text: Binding(get: { match }, set: { trigger = .inputDeviceConnected(match: $0) }))
            case .inputDeviceDisconnected(let match):
                TextField(L("automation.deviceMatch"), text: Binding(get: { match }, set: { trigger = .inputDeviceDisconnected(match: $0) }))
            case .profileActivated(let id):
                Picker("", selection: Binding(get: { id }, set: { trigger = .profileActivated($0) })) {
                    Text(L("automation.anyProfile")).tag(UUID?.none)
                    ForEach(KeystivoRuntime.shared.config.workspace.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden().fixedSize()
            case .typedText(let text):
                TextField(L("automation.typedTextPrompt"), text: Binding(get: { text }, set: { trigger = .typedText($0) }), prompt: Text(";;mail"))
                    .font(.system(.callout, design: .monospaced))
                Text(L("automation.typedTextHelp")).font(.caption2).foregroundStyle(.secondary)
            case .volumeMounted(let match):
                TextField(L("automation.volumeMatch"), text: Binding(get: { match }, set: { trigger = .volumeMounted(match: $0) }))
            case .volumeUnmounted(let match):
                TextField(L("automation.volumeMatch"), text: Binding(get: { match }, set: { trigger = .volumeUnmounted(match: $0) }))
            case .userIdle(let minutes):
                Stepper(L("automation.idleMinutes", minutes), value: Binding(get: { minutes }, set: { trigger = .userIdle(minutes: max(1, $0)) }), in: 1...240)
            case .urlScheme(let name):
                TextField(L("automation.urlName"), text: Binding(get: { name }, set: { trigger = .urlScheme(name: $0.replacingOccurrences(of: " ", with: "-")) }))
                    .font(.system(.callout, design: .monospaced))
                if !name.isEmpty {
                    HStack {
                        Text("keystivo://run/\(name)").font(.caption.monospaced()).textSelection(.enabled)
                        Button(L("launcher.action.copyURL")) { Pasteboard.copy("keystivo://run/\(name)") }.controlSize(.small)
                    }
                }
            default:
                EmptyView()
            }
        }
    }
}

struct WeekdayPicker: View {
    @Binding var weekdays: [Int]

    var body: some View {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        HStack(spacing: 3) {
            ForEach(1...7, id: \.self) { day in
                let selected = weekdays.contains(day)
                Text(symbols[day - 1])
                    .font(.caption2.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
                    .foregroundStyle(selected ? .white : .primary)
                    .onTapGesture {
                        if selected { weekdays.removeAll { $0 == day } } else { weekdays.append(day) }
                    }
            }
        }
        .help(L("automation.weekdaysHelp"))
    }
}

// MARK: - Conditions

struct ConditionGroupEditor: View {
    @Binding var condition: ConditionSpec
    let runtime: KeystivoRuntime

    var body: some View {
        let isAll: Bool = if case .any = condition { false } else { true }
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("automation.match"), selection: Binding(get: { isAll }, set: { all in condition = all ? .all(children) : .any(children) })) {
                Text(L("automation.matchAll")).tag(true)
                Text(L("automation.matchAny")).tag(false)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            ForEach(children.indices, id: \.self) { index in
                let fallback = children[index]
                HStack {
                    ConditionRow(condition: Binding(get: { children.indices.contains(index) ? children[index] : fallback }, set: { replace(index, with: $0) }), runtime: runtime)
                    Spacer()
                    Button { remove(index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            Menu {
                ForEach(Array(ConditionSpec.templates.enumerated()), id: \.offset) { _, template in
                    Button(L(template.titleKey)) { append(template) }
                }
                Divider()
                Button(L("condition.not")) { append(.not(.appRunning(bundleID: ""))) }
            } label: { Label(L("automation.addCondition"), systemImage: "plus") }
            .fixedSize()
        }
    }

    private var children: [ConditionSpec] {
        switch condition {
        case .all(let list), .any(let list): list
        default: [condition]
        }
    }

    private func setChildren(_ list: [ConditionSpec]) {
        if case .any = condition { condition = .any(list) } else { condition = .all(list) }
    }

    private func replace(_ index: Int, with value: ConditionSpec) {
        var list = children
        guard list.indices.contains(index) else { return }
        list[index] = value
        setChildren(list)
    }

    private func remove(_ index: Int) {
        var list = children
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        setChildren(list)
    }

    private func append(_ value: ConditionSpec) { setChildren(children + [value]) }
}

struct ConditionRow: View {
    @Binding var condition: ConditionSpec
    let runtime: KeystivoRuntime

    var body: some View {
        HStack {
            Text(L(condition.titleKey)).font(.callout)
            switch condition {
            case .appRunning(let id):
                AppPickerButton(bundleID: Binding(get: { id }, set: { condition = .appRunning(bundleID: $0) }))
            case .appNotRunning(let id):
                AppPickerButton(bundleID: Binding(get: { id }, set: { condition = .appNotRunning(bundleID: $0) }))
            case .appFrontmost(let id):
                AppPickerButton(bundleID: Binding(get: { id }, set: { condition = .appFrontmost(bundleID: $0) }))
            case .timeBetween(let start, let end):
                timePicker(start) { condition = .timeBetween(start: $0, end: end) }
                Text("–")
                timePicker(end) { condition = .timeBetween(start: start, end: $0) }
            case .weekdays(let days):
                WeekdayPicker(weekdays: Binding(get: { days }, set: { condition = .weekdays($0) }))
            case .powerSource(let source):
                Picker("", selection: Binding(get: { source }, set: { condition = .powerSource($0) })) {
                    ForEach(PowerSourceKind.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                .labelsHidden().fixedSize()
            case .batteryBelow(let percent):
                Stepper(L("automation.percent", percent), value: Binding(get: { percent }, set: { condition = .batteryBelow(percent: $0) }), in: 5...95, step: 5)
            case .batteryAbove(let percent):
                Stepper(L("automation.percent", percent), value: Binding(get: { percent }, set: { condition = .batteryAbove(percent: $0) }), in: 5...95, step: 5)
            case .displayCountAtLeast(let count):
                Stepper("\(count)", value: Binding(get: { count }, set: { condition = .displayCountAtLeast($0) }), in: 1...6)
            case .profileActive(let id):
                Picker("", selection: Binding(get: { id }, set: { condition = .profileActive($0) })) {
                    ForEach(runtime.config.workspace.profiles) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
            case .inputDeviceConnected(let match):
                TextField(L("automation.deviceMatch"), text: Binding(get: { match }, set: { condition = .inputDeviceConnected(match: $0) }))
            case .focusActive(let active):
                Toggle("", isOn: Binding(get: { active }, set: { condition = .focusActive($0) })).labelsHidden()
            case .variableEquals(let name, let value):
                variableField(name) { condition = .variableEquals(name: $0, value: value) }
                TextField(L("automation.value"), text: Binding(get: { value }, set: { condition = .variableEquals(name: name, value: $0) }))
            case .variableContains(let name, let value):
                variableField(name) { condition = .variableContains(name: $0, value: value) }
                TextField(L("automation.value"), text: Binding(get: { value }, set: { condition = .variableContains(name: name, value: $0) }))
            case .variableNotEmpty(let name):
                variableField(name) { condition = .variableNotEmpty(name: $0) }
            case .not(let inner):
                ConditionRow(condition: Binding(get: { inner }, set: { condition = .not($0) }), runtime: runtime)
            default:
                EmptyView()
            }
        }
    }

    private func variableField(_ name: String, set: @escaping (String) -> Void) -> some View {
        TextField(L("automation.variable"), text: Binding(get: { name }, set: set))
            .font(.system(.callout, design: .monospaced))
            .frame(width: 110)
    }

    private func timePicker(_ minutes: Int, set: @escaping (Int) -> Void) -> some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60)) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Steps

struct StepListEditor: View {
    @Binding var steps: [WorkflowStep]
    let runtime: KeystivoRuntime
    let depth: Int
    @State private var outputEditIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: safeElement($steps, index).isEnabled).labelsHidden().toggleStyle(.checkbox)
                    StepEditor(step: safeElement($steps, index), runtime: runtime, depth: depth)
                    Spacer(minLength: 0)
                    Menu {
                        Button(L("automation.moveUp")) { if index > 0 { steps.swapAt(index, index - 1) } }
                        Button(L("automation.moveDown")) { if index < steps.count - 1 { steps.swapAt(index, index + 1) } }
                        Toggle(L("automation.continueOnError"), isOn: safeElement($steps, index).continueOnError)
                        if case .action = steps[index].kind {
                            Button(L("automation.saveOutput")) { outputEditIndex = index }
                        }
                        Divider()
                        Button(L("common.delete"), role: .destructive) { if steps.indices.contains(index) { steps.remove(at: index) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035 + Double(depth) * 0.02)))
                if steps.indices.contains(index), outputEditIndex == index || !(steps[index].outputVariable ?? "").isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                        Text(L("automation.outputTo")).font(.caption).foregroundStyle(.secondary)
                        TextField("name", text: Binding(get: { steps.indices.contains(index) ? steps[index].outputVariable ?? "" : "" },
                                                        set: { if steps.indices.contains(index) { steps[index].outputVariable = $0.isEmpty ? nil : $0 } }))
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 120)
                        Text(L("automation.outputHelp")).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 26)
                }
            }
            Menu {
                ActionPickerMenu(onPick: { steps.append(WorkflowStep(.action($0.defaultInvocation()))) }) {
                    Label(L("automation.step.action"), systemImage: "bolt")
                }
                Button { steps.append(WorkflowStep(.delay(seconds: 1))) } label: { Label(L("automation.step.delay"), systemImage: "hourglass") }
                if depth < 3 {
                    Button { steps.append(WorkflowStep(.condition(.all([]), then: [], otherwise: []))) } label: { Label(L("automation.step.condition"), systemImage: "arrow.triangle.branch") }
                }
                Menu(L("automation.step.runWorkflow")) {
                    ForEach(runtime.config.automation.workflows) { workflow in
                        Button(workflow.name) { steps.append(WorkflowStep(.runWorkflow(workflow.id))) }
                    }
                }
                Divider()
                Button { steps.append(WorkflowStep(.setVariable(name: "name", value: "{{output}}"))) } label: { Label(L("automation.step.setVariable"), systemImage: "character.textbox") }
                if depth < 3 {
                    Button { steps.append(WorkflowStep(.repeatTimes(3, steps: []))) } label: { Label(L("automation.step.repeat"), systemImage: "repeat") }
                }
                Button { steps.append(WorkflowStep(.waitUntil(.appRunning(bundleID: ""), timeout: 30))) } label: { Label(L("automation.step.waitUntil"), systemImage: "hourglass.badge.plus") }
                Button { steps.append(WorkflowStep(.askInput(prompt: "", variable: "input"))) } label: { Label(L("automation.step.askInput"), systemImage: "text.bubble") }
                Button { steps.append(WorkflowStep(.showText("{{output}}"))) } label: { Label(L("automation.step.showText"), systemImage: "textformat.size.larger") }
                Divider()
                Button { steps.append(WorkflowStep(.stop)) } label: { Label(L("automation.step.stop"), systemImage: "stop.circle") }
            } label: { Label(L("automation.addStep"), systemImage: "plus") }
            .fixedSize()
        }
    }
}

private struct StepEditor: View {
    @Binding var step: WorkflowStep
    let runtime: KeystivoRuntime
    let depth: Int

    var body: some View {
        switch step.kind {
        case .action(let invocation):
            ActionInvocationEditor(invocation: Binding(get: { invocation }, set: { step.kind = .action($0) }))
        case .delay(let seconds):
            HStack {
                Label(L("automation.step.delay"), systemImage: "hourglass")
                Stepper(L("automation.seconds", seconds), value: Binding(get: { seconds }, set: { step.kind = .delay(seconds: max(0, $0)) }), in: 0...600, step: 0.5)
            }
        case .condition(let condition, let thenSteps, let elseSteps):
            VStack(alignment: .leading, spacing: 8) {
                Label(L("automation.step.if"), systemImage: "arrow.triangle.branch").font(.callout.weight(.semibold))
                ConditionGroupEditor(condition: Binding(get: { condition }, set: { step.kind = .condition($0, then: thenSteps, otherwise: elseSteps) }), runtime: runtime)
                Text(L("automation.step.then")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                StepListEditor(steps: Binding(get: { thenSteps }, set: { step.kind = .condition(condition, then: $0, otherwise: elseSteps) }), runtime: runtime, depth: depth + 1)
                Text(L("automation.step.otherwise")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                StepListEditor(steps: Binding(get: { elseSteps }, set: { step.kind = .condition(condition, then: thenSteps, otherwise: $0) }), runtime: runtime, depth: depth + 1)
            }
        case .runWorkflow(let id):
            Label(L("automation.step.runNamed", runtime.config.automation.workflows.first { $0.id == id }?.name ?? "?"), systemImage: "arrow.turn.down.right")
        case .stop:
            Label(L("automation.step.stop"), systemImage: "stop.circle")
        case .setVariable(let name, let value):
            HStack {
                Label(L("automation.step.setVariable"), systemImage: "character.textbox")
                TextField(L("automation.variable"), text: Binding(get: { name }, set: { step.kind = .setVariable(name: $0, value: value) }))
                    .font(.system(.callout, design: .monospaced)).frame(width: 110)
                Text("=")
                TextField(L("automation.value"), text: Binding(get: { value }, set: { step.kind = .setVariable(name: name, value: $0) }))
                    .font(.system(.callout, design: .monospaced))
            }
        case .repeatTimes(let times, let inner):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("automation.step.repeat"), systemImage: "repeat").font(.callout.weight(.semibold))
                    Stepper(L("automation.times", times), value: Binding(get: { times }, set: { step.kind = .repeatTimes(max(1, $0), steps: inner) }), in: 1...1000)
                }
                StepListEditor(steps: Binding(get: { inner }, set: { step.kind = .repeatTimes(times, steps: $0) }), runtime: runtime, depth: depth + 1)
            }
        case .waitUntil(let condition, let timeout):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("automation.step.waitUntil"), systemImage: "hourglass.badge.plus").font(.callout.weight(.semibold))
                    Stepper(L("automation.timeoutSeconds", Int(timeout)), value: Binding(get: { timeout }, set: { step.kind = .waitUntil(condition, timeout: max(1, $0)) }), in: 1...3600, step: 5)
                }
                ConditionRow(condition: Binding(get: { condition }, set: { step.kind = .waitUntil($0, timeout: timeout) }), runtime: runtime)
                Menu(L("automation.changeCondition")) {
                    ForEach(Array(ConditionSpec.templates.enumerated()), id: \.offset) { _, template in
                        Button(L(template.titleKey)) { step.kind = .waitUntil(template, timeout: timeout) }
                    }
                }
                .fixedSize()
            }
        case .askInput(let prompt, let variable):
            HStack {
                Label(L("automation.step.askInput"), systemImage: "text.bubble")
                TextField(L("automation.prompt"), text: Binding(get: { prompt }, set: { step.kind = .askInput(prompt: $0, variable: variable) }))
                Text("→")
                TextField(L("automation.variable"), text: Binding(get: { variable }, set: { step.kind = .askInput(prompt: prompt, variable: $0) }))
                    .font(.system(.callout, design: .monospaced)).frame(width: 100)
            }
        case .showText(let text):
            HStack {
                Label(L("automation.step.showText"), systemImage: "textformat.size.larger")
                TextField(L("automation.value"), text: Binding(get: { text }, set: { step.kind = .showText($0) }))
                    .font(.system(.callout, design: .monospaced))
            }
        }
    }
}

// MARK: - Library & history

private struct LibrarySheet: View {
    let onPick: (Workflow) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("automation.library")).font(.title3.weight(.semibold)).padding(16)
            List(AutomationLibrary.templates) { template in
                HStack(spacing: 12) {
                    SymbolTile(symbol: template.symbolName, color: .yellow, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(template.titleKey)).font(.headline)
                        Text(L(template.descriptionKey)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("common.add")) { onPick(template.make()) }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack { Spacer(); Button(L("common.close"), action: onCancel).keyboardShortcut(.cancelAction) }.padding(12)
        }
        .frame(width: 560, height: 480)
    }
}

private struct RunHistorySheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("automation.history")).font(.title3.weight(.semibold)).padding(16)
            List(AutomationEngine.shared.runs) { run in
                HStack {
                    RunStatusBadge(run: run)
                    VStack(alignment: .leading) {
                        Text(run.workflowName)
                        Text(run.trigger).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if let message = run.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(run.started.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack { Spacer(); Button(L("common.close"), action: onClose).keyboardShortcut(.cancelAction) }.padding(12)
        }
        .frame(width: 560, height: 480)
    }
}

/// A binding to one array element that tolerates the element being removed
/// while SwiftUI still renders its row (index bindings would crash).
func safeElement<T>(_ array: Binding<[T]>, _ index: Int) -> Binding<T> {
    let fallback = array.wrappedValue[index]
    return Binding(
        get: { array.wrappedValue.indices.contains(index) ? array.wrappedValue[index] : fallback },
        set: { if array.wrappedValue.indices.contains(index) { array.wrappedValue[index] = $0 } }
    )
}
