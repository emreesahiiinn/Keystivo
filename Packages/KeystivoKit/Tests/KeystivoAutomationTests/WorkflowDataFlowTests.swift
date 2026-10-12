import Foundation
@testable import KeystivoAutomation
import KeystivoCore
import Testing

@Suite("Workflow data flow")
@MainActor
struct WorkflowDataFlowTests {
    private func makeEngine(log: @escaping (String) -> Void) -> AutomationEngine {
        let registry = ActionRegistry()
        registry.register(ActionDescriptor(id: "log", titleKey: "log", symbol: "x", category: .automation,
                                           parameters: [ParameterSpec("text", "t", .text)])) { arguments, _ in
            log(arguments.string("text") ?? "")
        }
        registry.register(ActionDescriptor(id: "echo", titleKey: "echo", symbol: "x", category: .automation,
                                           parameters: [ParameterSpec("text", "t", .text)])) { arguments, context in
            context.emit((arguments.string("text") ?? "").uppercased())
        }
        let engine = AutomationEngine(registry: registry)
        engine.environment = MockEnvironment()
        return engine
    }

    private func waitForRuns(_ engine: AutomationEngine) async {
        for _ in 0..<400 where !engine.runningWorkflowIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func outputsAndVariablesFlowBetweenSteps() async {
        var log: [String] = []
        let engine = makeEngine { log.append($0) }
        var echo = WorkflowStep.action("echo", ["text": .string("hello")])
        echo.outputVariable = "greeting"
        engine.workflows = [Workflow(name: "Flow", triggers: [.manual], steps: [
            echo,
            .action("log", ["text": .string("{{output}} / {{greeting}} / {{workflow}}")]),
            WorkflowStep(.setVariable(name: "name", value: "{{greeting}}!")),
            WorkflowStep(.condition(.variableEquals(name: "name", value: "HELLO!"), then: [.action("log", ["text": .string("equal")])], otherwise: [])),
            WorkflowStep(.condition(.variableContains(name: "missing", value: "x"), then: [.action("log", ["text": .string("never")])], otherwise: [.action("log", ["text": .string("else")])])),
        ])]
        engine.run(engine.workflows[0])
        await waitForRuns(engine)
        #expect(log == ["HELLO / HELLO / Flow", "equal", "else"])
    }

    @Test func repeatCountsWithIndex() async {
        var log: [String] = []
        let engine = makeEngine { log.append($0) }
        engine.workflows = [Workflow(name: "Loop", triggers: [.manual], steps: [
            WorkflowStep(.repeatTimes(3, steps: [.action("log", ["text": .string("#{{index}}")])])),
        ])]
        engine.run(engine.workflows[0])
        await waitForRuns(engine)
        #expect(log == ["#1", "#2", "#3"])
    }

    @Test func waitUntilTimesOut() async {
        let engine = makeEngine { _ in }
        engine.workflows = [Workflow(name: "Wait", triggers: [.manual], steps: [
            WorkflowStep(.waitUntil(.appRunning(bundleID: "never.running"), timeout: 0.6)),
        ])]
        engine.run(engine.workflows[0])
        await waitForRuns(engine)
        #expect(engine.runs.first?.status == .failed)
    }

    @Test func askInputStoresAnswerOrStops() async {
        var log: [String] = []
        let engine = makeEngine { log.append($0) }
        engine.onAskInput = { prompt, _ in prompt == "Name?" ? "Emre" : nil }
        engine.workflows = [Workflow(name: "Ask", triggers: [.manual], steps: [
            WorkflowStep(.askInput(prompt: "Name?", variable: "who")),
            .action("log", ["text": .string("hi {{who}}")]),
            WorkflowStep(.askInput(prompt: "Cancel me", variable: "x")),
            .action("log", ["text": .string("never")]),
        ])]
        engine.run(engine.workflows[0])
        await waitForRuns(engine)
        #expect(log == ["hi Emre"])
        #expect(engine.runs.first?.status == .cancelled)
    }

    @Test func urlTriggersPassParameters() async {
        var log: [String] = []
        let engine = makeEngine { log.append($0) }
        engine.workflows = [Workflow(name: "Deck", triggers: [.urlScheme(name: "stream-deck")], steps: [
            .action("log", ["text": .string("{{key}}")]),
        ])]
        engine.handleURL(name: "Stream-Deck", parameters: ["key": "value"])
        engine.handleURL(name: "other", parameters: [:])
        await waitForRuns(engine)
        #expect(log == ["value"])
    }

    @Test func newTriggersMatch() {
        #expect(TriggerSpec.typedText(";;mail").matches(.typedText(";;mail")))
        #expect(!TriggerSpec.typedText("").matches(.typedText("")))
        #expect(TriggerSpec.volumeMounted(match: "").matches(.volumeMounted("Backup")))
        #expect(TriggerSpec.volumeMounted(match: "back").matches(.volumeMounted("Backup")))
        #expect(!TriggerSpec.volumeMounted(match: "usb").matches(.volumeMounted("Backup")))
        #expect(TriggerSpec.userIdle(minutes: 5).matches(.userIdle(minutes: 5)))
        #expect(!TriggerSpec.userIdle(minutes: 5).matches(.userIdle(minutes: 6)))
        #expect(TriggerSpec.clipboardChanged.matches(.clipboardChanged))
    }

    @Test func placeholdersExpand() {
        #expect(Placeholders.expand("a {{x}} b {{ y }} {{missing}}c", variables: ["x": "1", "y": "2"]) == "a 1 b 2 c")
        #expect(Placeholders.expand("no braces", variables: [:]) == "no braces")
        #expect(Placeholders.expand("open {{x", variables: ["x": "1"]) == "open {{x")
        #expect(!Placeholders.expand("{{uuid}}", variables: [:]).isEmpty)
    }
}
