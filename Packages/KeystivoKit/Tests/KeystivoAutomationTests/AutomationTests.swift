import Foundation
@testable import KeystivoAutomation
import KeystivoCore
import Testing

/// Deterministic environment for condition tests.
final class MockEnvironment: AutomationEnvironment {
    var now = Date(timeIntervalSince1970: 1_760_000_000)
    var calendar = Calendar(identifier: .gregorian)
    var frontmostBundleID: String?
    var running: Set<String> = []
    var powerSource: PowerSourceKind = .ac
    var batteryLevel: Int? = 80
    var displayCount = 1
    var activeProfileID: UUID?
    var audioOutputUID: String?
    var connectedInputDeviceNames: [String] = []
    var isFocusActive = false

    init() { calendar.timeZone = TimeZone(identifier: "UTC")! }
    func isRunning(_ bundleID: String) -> Bool { running.contains(bundleID) }

    func setTime(hour: Int, minute: Int, weekday: Int) {
        // 2025-10-05 was a Sunday (weekday 1).
        let base = calendar.date(from: DateComponents(year: 2025, month: 10, day: 5, hour: hour, minute: minute))!
        now = calendar.date(byAdding: .day, value: weekday - 1, to: base)!
    }
}

@Suite("Triggers")
struct TriggerTests {
    @Test func appTriggersMatchSpecificAndAny() {
        #expect(TriggerSpec.appLaunched(bundleID: "a").matches(.appLaunched("a")))
        #expect(!TriggerSpec.appLaunched(bundleID: "a").matches(.appLaunched("b")))
        #expect(TriggerSpec.appLaunched(bundleID: "").matches(.appLaunched("b")))
        #expect(!TriggerSpec.appLaunched(bundleID: "").matches(.appQuit("b")))
    }

    @Test func scheduleMatchesTimeAndWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday9 = calendar.date(from: DateComponents(year: 2025, month: 10, day: 6, hour: 9, minute: 0))!
        #expect(TriggerSpec.schedule(hour: 9, minute: 0, weekdays: []).matches(.scheduleTick(monday9), calendar: calendar))
        #expect(TriggerSpec.schedule(hour: 9, minute: 0, weekdays: [2]).matches(.scheduleTick(monday9), calendar: calendar))
        #expect(!TriggerSpec.schedule(hour: 9, minute: 0, weekdays: [1, 7]).matches(.scheduleTick(monday9), calendar: calendar))
        #expect(!TriggerSpec.schedule(hour: 9, minute: 1, weekdays: []).matches(.scheduleTick(monday9), calendar: calendar))
    }

    @Test func batteryFiresOnlyWhenCrossing() {
        let trigger = TriggerSpec.batteryBelow(percent: 20)
        #expect(trigger.matches(.batteryLevel(19, previous: 20)))
        #expect(!trigger.matches(.batteryLevel(18, previous: 19)))
        #expect(!trigger.matches(.batteryLevel(25, previous: 30)))
    }

    @Test func powerAndDevices() {
        #expect(TriggerSpec.powerSourceChanged(to: .any).matches(.powerSourceChanged(.battery)))
        #expect(!TriggerSpec.powerSourceChanged(to: .ac).matches(.powerSourceChanged(.battery)))
        #expect(TriggerSpec.inputDeviceConnected(match: "magic").matches(.inputDeviceConnected("Magic Mouse")))
    }

    @Test func everyTemplateHasTitleAndSymbol() {
        for template in TriggerSpec.templates {
            #expect(template.titleKey.hasPrefix("trigger."))
            #expect(!template.symbolName.isEmpty)
        }
    }
}

@Suite("Conditions")
struct ConditionTests {
    @Test func timeWindowsIncludingOvernight() {
        let environment = MockEnvironment()
        environment.setTime(hour: 23, minute: 30, weekday: 2)
        #expect(ConditionEvaluator.evaluate(.timeBetween(start: 22 * 60, end: 6 * 60), in: environment))
        #expect(!ConditionEvaluator.evaluate(.timeBetween(start: 9 * 60, end: 18 * 60), in: environment))
        environment.setTime(hour: 10, minute: 0, weekday: 2)
        #expect(ConditionEvaluator.evaluate(.timeBetween(start: 9 * 60, end: 18 * 60), in: environment))
        #expect(ConditionEvaluator.evaluate(.weekdays([2, 3, 4, 5, 6]), in: environment))
    }

    @Test func compositeConditions() {
        let environment = MockEnvironment()
        environment.running = ["us.zoom.xos"]
        environment.powerSource = .battery
        environment.batteryLevel = 15
        let condition = ConditionSpec.all([.appRunning(bundleID: "us.zoom.xos"), .any([.powerSource(.ac), .batteryBelow(percent: 20)]), .not(.focusActive(true))])
        #expect(ConditionEvaluator.evaluate(condition, in: environment))
        environment.isFocusActive = true
        #expect(!ConditionEvaluator.evaluate(condition, in: environment))
    }

    @Test func emptyAnyIsTrue() {
        #expect(ConditionEvaluator.evaluate(.any([]), in: MockEnvironment()))
        #expect(ConditionEvaluator.evaluate(.all([]), in: MockEnvironment()))
    }
}

@Suite("Workflow engine")
struct WorkflowEngineTests {
    private func makeEngine(log: @escaping (String) -> Void) -> AutomationEngine {
        let registry = ActionRegistry()
        registry.register(ActionDescriptor(id: "log", titleKey: "log", symbol: "x", category: .automation,
                                           parameters: [ParameterSpec("text", "t", .text)])) { arguments, _ in
            log(arguments.string("text") ?? "")
        }
        registry.register(ActionDescriptor(id: "fail", titleKey: "fail", symbol: "x", category: .automation)) { _, _ in
            throw ActionError.failed("nope")
        }
        let engine = AutomationEngine(registry: registry)
        engine.environment = MockEnvironment()
        return engine
    }

    private func waitForRuns(_ engine: AutomationEngine) async {
        for _ in 0..<200 where !engine.runningWorkflowIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func runsMatchingWorkflowStepsInOrder() async {
        var log: [String] = []
        let engine = makeEngine { log.append($0) }
        let environment = MockEnvironment()
        environment.running = ["app"]
        engine.environment = environment
        engine.workflows = [Workflow(name: "W", triggers: [.appLaunched(bundleID: "x")], steps: [
            .action("log", ["text": .string("1")]),
            WorkflowStep(.condition(.appRunning(bundleID: "app"), then: [.action("log", ["text": .string("then")])], otherwise: [.action("log", ["text": .string("else")])])),
            .action("log", ["text": .string("2")]),
        ])]
        engine.handle(.appLaunched("x"))
        await waitForRuns(engine)
        #expect(log == ["1", "then", "2"])
        #expect(engine.runs.first?.status == .succeeded)
    }

    @Test func conditionBlocksRun() async {
        var log: [String] = []
        let engine = makeEngine { log.append($0) }
        engine.workflows = [Workflow(name: "W", triggers: [.manual], condition: .appRunning(bundleID: "missing"), steps: [.action("log", ["text": .string("x")])])]
        engine.run(engine.workflows[0])
        await waitForRuns(engine)
        #expect(log.isEmpty)
    }

    @Test func failureStopsUnlessContinueOnError() async {
        var log: [String] = []
        let engine = makeEngine { log.append($0) }
        var tolerant = WorkflowStep.action("fail")
        tolerant.continueOnError = true
        engine.workflows = [Workflow(name: "W", triggers: [.manual], steps: [tolerant, .action("log", ["text": .string("after")]), .action("fail"), .action("log", ["text": .string("never")])])]
        engine.run(engine.workflows[0])
        await waitForRuns(engine)
        #expect(log == ["after"])
        #expect(engine.runs.first?.status == .failed)
    }

    @Test func disabledWorkflowsAndProfilesAreSkipped() {
        let engine = makeEngine { _ in }
        let work = UUID()
        var scoped = Workflow(name: "Scoped", triggers: [.manual], steps: [])
        scoped.profileIDs = [work]
        var disabled = Workflow(name: "Off", triggers: [.manual], steps: [])
        disabled.isEnabled = false
        engine.workflows = [scoped, disabled]
        #expect(engine.activeWorkflows.isEmpty)
        engine.activeProfileID = work
        #expect(engine.activeWorkflows.map(\.name) == ["Scoped"])
    }

    @Test func stopStepEndsSuccessfully() async {
        var log: [String] = []
        let engine = makeEngine { log.append($0) }
        engine.workflows = [Workflow(name: "W", triggers: [.manual], steps: [WorkflowStep(.stop), .action("log", ["text": .string("x")])])]
        engine.run(engine.workflows[0])
        await waitForRuns(engine)
        #expect(log.isEmpty)
        #expect(engine.runs.first?.status == .succeeded)
    }
}

@Suite("Library & sharing")
struct LibraryTests {
    @Test func exportImportRoundTripAssignsNewIDs() throws {
        let original = Workflow(name: "Share me", triggers: [.hotkey(KeyCombo(keyCode: 1, modifiers: .hyper)), .schedule(hour: 8, minute: 30, weekdays: [2])],
                                condition: .not(.focusActive(true)), steps: [.action("x", ["n": .number(3)]), WorkflowStep(.delay(seconds: 1))])
        let data = try AutomationLibrary.export([original])
        let imported = try AutomationLibrary.import(data)
        #expect(imported.count == 1)
        #expect(imported[0].id != original.id)
        #expect(imported[0].isEnabled == false)
        #expect(imported[0].steps.count == 2)
        #expect(imported[0].triggers == original.triggers)
        #expect(imported[0].condition == original.condition)
    }

    @Test func rejectsForeignFiles() {
        #expect(throws: (any Error).self) { try AutomationLibrary.import(Data("{\"format\":\"other\",\"version\":1,\"exportedAt\":\"2025-01-01T00:00:00Z\",\"workflows\":[]}".utf8)) }
    }

    @Test func templatesBuildValidWorkflows() {
        for template in AutomationLibrary.templates {
            let workflow = template.make()
            #expect(!workflow.triggers.isEmpty)
            #expect(!workflow.steps.isEmpty)
        }
    }
}
