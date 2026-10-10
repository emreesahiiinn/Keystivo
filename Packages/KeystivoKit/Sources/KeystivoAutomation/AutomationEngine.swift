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
            registerHotkeys()
            scheduler.update(workflows: activeWorkflows)
        }
    }
    public var isEnabled = true {
        didSet { registerHotkeys(); scheduler.update(workflows: activeWorkflows) }
    }
    public var activeProfileID: UUID? {
        didSet { registerHotkeys(); scheduler.update(workflows: activeWorkflows) }
    }
    public private(set) var runs: [WorkflowRun] = []
    public private(set) var runningWorkflowIDs: Set<UUID> = []

    @ObservationIgnored public var onChange: (([Workflow]) -> Void)?
    @ObservationIgnored public var environment: (any AutomationEnvironment)?
    @ObservationIgnored private var hotkeyTokens: [HotKeyToken] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let scheduler = AutomationScheduler()
    @ObservationIgnored private let registry: ActionRegistry

    public init(registry: ActionRegistry = .shared) {
        self.registry = registry
        scheduler.onEvent = { [weak self] event in self?.handle(event) }
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

    /// Runs a workflow now (manual triggers, launcher, other workflows).
    public func run(_ workflow: Workflow, trigger: String = "manual") {
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
            do {
                try await execute(workflow.steps, workflow: workflow, depth: 0)
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

    private func execute(_ steps: [WorkflowStep], workflow: Workflow, depth: Int) async throws {
        guard depth < 8 else { throw ActionError.failed(L("automation.error.recursion")) }
        for step in steps where step.isEnabled {
            try Task.checkCancellation()
            do {
                switch step.kind {
                case .action(let invocation):
                    try await registry.perform(invocation, context: ActionContext(source: .workflow, variables: ["workflow": workflow.name]))
                case .delay(let seconds):
                    try await Task.sleep(for: .milliseconds(Int(max(seconds, 0) * 1000)))
                case .condition(let condition, let thenSteps, let elseSteps):
                    let passed = environment.map { ConditionEvaluator.evaluate(condition, in: $0) } ?? false
                    try await execute(passed ? thenSteps : elseSteps, workflow: workflow, depth: depth + 1)
                case .runWorkflow(let id):
                    guard let nested = workflows.first(where: { $0.id == id }), nested.id != workflow.id else { continue }
                    try await execute(nested.steps, workflow: nested, depth: depth + 1)
                case .stop:
                    throw StopSignal.stop
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
            for combo in workflow.hotkeys where seen.insert(combo).inserted {
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
            if now.timeIntervalSince(last) >= TimeInterval(minutes * 60) - 5 {
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
