import AppKit
import KeystivoCore
import Observation

nonisolated public struct WorkflowRun: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable { case running, succeeded, failed, cancelled, skipped }

    public let id: UUID
    public let workflowID: UUID
    public let workflowName: String
    public let trigger: String
    public let started: Date
    public var finished: Date?
    public var status: Status
    public var message: String?
}

/// Matches events to workflows, checks conditions and runs steps.
@Observable
public final class AutomationEngine {
    public static let shared = AutomationEngine()

    public var workflows: [Workflow] = [] {
        didSet {
            onChange?(workflows)
            refreshTriggers()
        }
    }
    public var isEnabled = true {
        didSet { refreshTriggers() }
    }
    public var activeProfileID: UUID? {
        didSet { refreshTriggers() }
    }

    private func refreshTriggers() {
        registerHotkeys()
        scheduler.update(workflows: activeWorkflows)
        TypedTextTriggers.shared.triggers = Set(activeWorkflows.flatMap { $0.triggers.compactMap(\.typedText) })
    }
    public private(set) var runs: [WorkflowRun] = []
    public private(set) var runningWorkflowIDs: Set<UUID> = []

    @ObservationIgnored public var onChange: (([Workflow]) -> Void)?
    @ObservationIgnored public var environment: (any AutomationEnvironment)?
    /// UI hooks for interactive steps (the engine itself has no UI).
    @ObservationIgnored public var onAskInput: (@MainActor (_ prompt: String, _ workflow: String) async -> String?)?
    @ObservationIgnored public var onShowText: (@MainActor (_ text: String, _ workflow: String) -> Void)?
    @ObservationIgnored private var hotkeyTokens: [HotKeyToken] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let scheduler = AutomationScheduler()
    @ObservationIgnored private let registry: ActionRegistry

    public init(registry: ActionRegistry = .shared) {
        self.registry = registry
        scheduler.onEvent = { [weak self] event in self?.handle(event) }
        TypedTextTriggers.shared.onMatch = { [weak self] text in self?.handle(.typedText(text)) }
        EventTapManager.shared.add(TypedTextTriggers.shared)
    }

    public var activeWorkflows: [Workflow] {
        guard isEnabled else { return [] }
        return workflows.filter { $0.isEnabled && ($0.profileIDs.isEmpty || activeProfileID.map($0.profileIDs.contains) == true) }
    }

    // MARK: Events

    public func handle(_ event: AutomationEvent) {
        for workflow in activeWorkflows where workflow.triggers.contains(where: { $0.matches(event) }) {
            run(workflow, trigger: String(describing: event))
        }
    }

    /// `keystivo://run/<name>?key=value`: runs workflows with that URL trigger;
    /// the query items become {{key}} variables.
    public func handleURL(name: String, parameters: [String: String]) {
        for workflow in activeWorkflows where workflow.triggers.contains(where: { $0.matches(.url(name)) }) {
            run(workflow, trigger: "keystivo://run/\(name)", variables: parameters)
        }
    }

    /// Runs a workflow now (manual triggers, launcher, other workflows).
    public func run(_ workflow: Workflow, trigger: String = "manual", variables: [String: String] = [:]) {
        if workflow.preventsOverlap, runningWorkflowIDs.contains(workflow.id) {
            record(WorkflowRun(id: UUID(), workflowID: workflow.id, workflowName: workflow.name, trigger: trigger, started: .now, finished: .now, status: .skipped, message: L("automation.run.overlap")))
            return
        }
        if let condition = workflow.condition, let environment, !ConditionEvaluator.evaluate(condition, in: environment) {
            return
        }
        let runID = UUID()
        record(WorkflowRun(id: runID, workflowID: workflow.id, workflowName: workflow.name, trigger: trigger, started: .now, status: .running))
        runningWorkflowIDs.insert(workflow.id)
        tasks[runID] = Task {
            var status = WorkflowRun.Status.succeeded
            var message: String?
            let state = RunState(workflow: workflow.name, trigger: trigger)
            state.variables.merge(variables) { _, new in new }
            do {
                try await execute(workflow.steps, workflow: workflow, depth: 0, state: state)
            } catch is CancellationError {
                status = .cancelled
            } catch StopSignal.stop {
                status = .succeeded
            } catch {
                status = .failed
                message = error.localizedDescription
                DiagnosticsCenter.shared.record(.error, module: "Automation", L("automation.run.failed", workflow.name), detail: message)
            }
            finish(runID, workflowID: workflow.id, status: status, message: message)
        }
    }

    public func run(workflowID: UUID) throws(ActionError) {
        guard let workflow = workflows.first(where: { $0.id == workflowID }) else { throw .notAvailable(L("automation.error.missingWorkflow")) }
        run(workflow)
    }

    public func cancel(workflowID: UUID) {
        for run in runs where run.workflowID == workflowID && run.status == .running {
            tasks[run.id]?.cancel()
        }
    }

    private enum StopSignal: Error { case stop }

    /// Variables of one run, shared by its steps (and nested workflows).
    final class RunState {
        var variables: [String: String]
        init(workflow: String, trigger: String) { variables = ["workflow": workflow, "trigger": trigger] }
    }

    private func evaluate(_ condition: ConditionSpec, state: RunState) -> Bool {
        guard let environment else { return false }
        return ConditionEvaluator.evaluate(condition, in: environment, variables: state.variables)
    }

    private func execute(_ steps: [WorkflowStep], workflow: Workflow, depth: Int, state: RunState) async throws {
        guard depth < 8 else { throw ActionError.failed(L("automation.error.recursion")) }
        for step in steps where step.isEnabled {
            try Task.checkCancellation()
            do {
                switch step.kind {
                case .action(let invocation):
                    let sink = ActionOutputSink()
                    let expanded = Placeholders.expand(invocation, variables: state.variables)
                    try await registry.perform(expanded, context: ActionContext(source: .workflow, variables: state.variables, output: sink))
                    if let output = sink.text {
                        state.variables["output"] = output
                        if let name = step.outputVariable?.trimmingCharacters(in: .whitespaces), !name.isEmpty { state.variables[name] = output }
                    }
                case .delay(let seconds):
                    // Imported workflows can carry any number: keep it finite and at most a day.
                    try await Task.sleep(for: .milliseconds((min(max(seconds.finite(or: 0), 0), 86_400) * 1000).safeInt))
                case .condition(let condition, let thenSteps, let elseSteps):
                    try await execute(evaluate(condition, state: state) ? thenSteps : elseSteps, workflow: workflow, depth: depth + 1, state: state)
                case .runWorkflow(let id):
                    // The nested workflow's own switch and condition still apply.
                    guard let nested = workflows.first(where: { $0.id == id }) else { throw ActionError.notAvailable(L("automation.error.missingWorkflow")) }
                    guard nested.id != workflow.id, nested.isEnabled else { continue }
                    if let condition = nested.condition, !evaluate(condition, state: state) { continue }
                    try await execute(nested.steps, workflow: nested, depth: depth + 1, state: state)
                case .stop:
                    throw StopSignal.stop
                case .setVariable(let name, let value):
                    let key = name.trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { state.variables[key] = Placeholders.expand(value, variables: state.variables) }
                case .repeatTimes(let times, let inner):
                    for index in 1...max(1, min(times, 1000)) {
                        try Task.checkCancellation()
                        state.variables["index"] = String(index)
                        try await execute(inner, workflow: workflow, depth: depth + 1, state: state)
                    }
                case .waitUntil(let condition, let timeout):
                    let deadline = Date.now.addingTimeInterval(max(timeout, 0.5))
                    while !evaluate(condition, state: state) {
                        guard Date.now < deadline else { throw ActionError.failed(L("automation.error.waitTimeout")) }
                        try await Task.sleep(for: .milliseconds(250))
                    }
                case .askInput(let prompt, let variable):
                    guard let onAskInput, let answer = await onAskInput(Placeholders.expand(prompt, variables: state.variables), workflow.name) else {
                        throw CancellationError()
                    }
                    let key = variable.trimmingCharacters(in: .whitespaces)
                    state.variables[key.isEmpty ? "input" : key] = answer
                case .showText(let text):
                    onShowText?(Placeholders.expand(text, variables: state.variables), workflow.name)
                }
            } catch let error where !(error is CancellationError) && !(error is StopSignal) && step.continueOnError {
                DiagnosticsCenter.shared.record(.warning, module: "Automation", error.localizedDescription)
            }
        }
    }

    private func record(_ run: WorkflowRun) {
        runs.insert(run, at: 0)
        if runs.count > 200 { runs.removeLast(runs.count - 200) }
    }

    private func finish(_ runID: UUID, workflowID: UUID, status: WorkflowRun.Status, message: String?) {
        tasks[runID] = nil
        runningWorkflowIDs.remove(workflowID)
        if let index = runs.firstIndex(where: { $0.id == runID }) {
            runs[index].status = status
            runs[index].finished = .now
            runs[index].message = message
        }
    }

    // MARK: Hotkey triggers

    private func registerHotkeys() {
        for token in hotkeyTokens { HotKeyCenter.shared.unregister(token) }
        hotkeyTokens.removeAll()
        var seen = Set<KeyCombo>()
        for workflow in activeWorkflows {
            for combo in workflow.hotkeys where !combo.isUnset && seen.insert(combo).inserted {
                do {
                    hotkeyTokens.append(try HotKeyCenter.shared.register(combo) { [weak self] in
                        self?.handle(.hotkey(combo))
                    })
                } catch {
                    DiagnosticsCenter.shared.record(.warning, module: "Automation", L("automation.error.hotkey", workflow.name, error.localizedDescription))
                }
            }
        }
    }
}

/// One timer for all schedule/interval triggers; sleeps until the next due minute.
final class AutomationScheduler {
    var onEvent: (@MainActor (AutomationEvent) -> Void)?
    private var timer: Timer?
    private var intervals: Set<Int> = []
    private var hasSchedules = false
    private var lastIntervalFire: [Int: Date] = [:]

    func update(workflows: [Workflow]) {
        intervals = []
        hasSchedules = false
        for trigger in workflows.flatMap(\.triggers) {
            switch trigger {
            case .schedule: hasSchedules = true
            case .interval(let minutes) where minutes > 0: intervals.insert(minutes)
            default: break
            }
        }
        timer?.invalidate()
        timer = nil
        guard hasSchedules || !intervals.isEmpty else { return }
        scheduleNextTick()
    }

    private func scheduleNextTick() {
        let calendar = Calendar.current
        let now = Date.now
        guard let next = calendar.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date.now
        if hasSchedules { onEvent?(.scheduleTick(now)) }
        for minutes in intervals {
            let last = lastIntervalFire[minutes] ?? .distantPast
            if now.timeIntervalSince(last) >= TimeInterval(minutes) * 60 - 5 {
                if lastIntervalFire[minutes] != nil { onEvent?(.interval(minutes: minutes)) }
                lastIntervalFire[minutes] = now
            }
        }
        scheduleNextTick()
    }
}

/// Forwards workspace, display, sleep and lock notifications as automation events.
public final class SystemEventSource {
    public var onEvent: (@MainActor (AutomationEvent) -> Void)?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var displayCount = NSScreen.screens.count

    public init() {}

    public func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        func observeApp(_ name: Notification.Name, _ make: @escaping @Sendable (String) -> AutomationEvent) {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.onEvent?(make(id)) }
            }))
        }
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: AutomationEvent) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(event) }
            }))
        }
        observeApp(NSWorkspace.didLaunchApplicationNotification) { .appLaunched($0) }
        observeApp(NSWorkspace.didTerminateApplicationNotification) { .appQuit($0) }
        observeApp(NSWorkspace.didActivateApplicationNotification) { .appActivated($0) }
        observeApp(NSWorkspace.didDeactivateApplicationNotification) { .appDeactivated($0) }
        observe(workspace, NSWorkspace.didWakeNotification, .systemWake)
        observe(workspace, NSWorkspace.willSleepNotification, .systemSleep)
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }))
    }

    private func screensChanged() {
        let count = NSScreen.screens.count
        defer { displayCount = count }
        if count > displayCount { onEvent?(.displayConnected) }
        if count < displayCount { onEvent?(.displayDisconnected) }
    }

    public func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}
