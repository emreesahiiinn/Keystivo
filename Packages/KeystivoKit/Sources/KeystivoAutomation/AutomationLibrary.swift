import Foundation
import KeystivoCore
import UniformTypeIdentifiers

/// Built-in templates and sharing ("otomasyon kütüphanesi ve paylaşım").
public enum AutomationLibrary {
    public struct Template: Identifiable, Sendable {
        public let id: String
        public let titleKey: String
        public let descriptionKey: String
        public let symbolName: String
        public let make: @Sendable () -> Workflow
    }

    public static let templates: [Template] = [
        Template(id: "meeting", titleKey: "library.meeting.title", descriptionKey: "library.meeting.description", symbolName: "video") {
            var workflow = Workflow(
                name: L("library.meeting.title"),
                triggers: [.appLaunched(bundleID: "us.zoom.xos"), .appLaunched(bundleID: "com.microsoft.teams2")],
                steps: [
                    .action("audio.setAppMuted", ["bundleID": .string("com.apple.Music"), "muted": .bool(true)]),
                    .action("audio.setAppMuted", ["bundleID": .string("com.spotify.client"), "muted": .bool(true)]),
                    .action("audio.setMicMuted", ["muted": .bool(false)]),
                    .action("system.notify", ["title": .string(L("library.meeting.title")), "body": .string(L("library.meeting.notification"))]),
                ]
            )
            workflow.symbolName = "video"
            return workflow
        },
        Template(id: "battery", titleKey: "library.battery.title", descriptionKey: "library.battery.description", symbolName: "battery.25percent") {
            var workflow = Workflow(
                name: L("library.battery.title"),
                triggers: [.powerSourceChanged(to: .battery)],
                condition: .batteryBelow(percent: 50),
                steps: [
                    .action("power.applyProfile", ["profile": .string("saver")]),
                    .action("system.notify", ["title": .string(L("library.battery.title")), "body": .string(L("library.battery.notification"))]),
                ]
            )
            workflow.symbolName = "battery.25percent"
            return workflow
        },
        Template(id: "dock", titleKey: "library.dock.title", descriptionKey: "library.dock.description", symbolName: "display.2") {
            var workflow = Workflow(
                name: L("library.dock.title"),
                triggers: [.displayConnected],
                condition: .displayCountAtLeast(2),
                steps: [
                    WorkflowStep(.delay(seconds: 2)),
                    .action("windows.gatherToScreen"),
                    .action("audio.cycleOutput"),
                ]
            )
            workflow.symbolName = "display.2"
            return workflow
        },
        Template(id: "evening", titleKey: "library.evening.title", descriptionKey: "library.evening.description", symbolName: "moon.stars") {
            var workflow = Workflow(
                name: L("library.evening.title"),
                triggers: [.schedule(hour: 19, minute: 0, weekdays: [2, 3, 4, 5, 6])],
                steps: [
                    .action("apps.quit", ["bundleID": .string("com.tinyspeck.slackmacgap")]),
                    .action("apps.quit", ["bundleID": .string("com.microsoft.Outlook")]),
                    .action("system.notify", ["title": .string(L("library.evening.title")), "body": .string(L("library.evening.notification"))]),
                ]
            )
            workflow.symbolName = "moon.stars"
            return workflow
        },
        Template(id: "focusCoding", titleKey: "library.coding.title", descriptionKey: "library.coding.description", symbolName: "chevron.left.forwardslash.chevron.right") {
            var workflow = Workflow(
                name: L("library.coding.title"),
                triggers: [.manual],
                steps: [
                    .action("apps.launch", ["bundleID": .string("com.apple.dt.Xcode")]),
                    .action("apps.launch", ["bundleID": .string("com.apple.Terminal")]),
                    WorkflowStep(.delay(seconds: 1.5)),
                    .action("windows.arrange", ["style": .string("masterStack"), "scope": .string("currentScreen")]),
                    .action("focus.start", ["minutes": .number(50)]),
                ]
            )
            workflow.symbolName = "chevron.left.forwardslash.chevron.right"
            return workflow
        },
        Template(id: "headphones", titleKey: "library.headphones.title", descriptionKey: "library.headphones.description", symbolName: "headphones") {
            var workflow = Workflow(
                name: L("library.headphones.title"),
                triggers: [.audioOutputChanged],
                steps: [.action("audio.setVolume", ["level": .number(40)])]
            )
            workflow.symbolName = "headphones"
            return workflow
        },
    ]

    // MARK: Sharing

    /// File type for shared workflows (".keystivoflow", JSON inside).
    public static let fileExtension = "keystivoflow"

    nonisolated struct SharedFile: Codable {
        var format = "com.keystivo.workflow"
        var version = 1
        var exportedAt = Date.now
        var workflows: [Workflow]
    }

    public static func export(_ workflows: [Workflow]) throws -> Data {
        try JSONFileStore<SharedFile>.encoder.encode(SharedFile(workflows: workflows))
    }

    /// Imports workflows, assigning fresh IDs so imports never overwrite existing ones.
    /// Imported hotkey triggers are kept but workflows arrive disabled for review.
    public static func `import`(_ data: Data) throws -> [Workflow] {
        let file = try JSONFileStore<SharedFile>.decoder.decode(SharedFile.self, from: data)
        guard file.format == "com.keystivo.workflow" else { throw ActionError.failed(L("library.error.format")) }
        return file.workflows.map { workflow in
            var copy = workflow
            copy.id = UUID()
            copy.isEnabled = false
            copy.profileIDs = []
            return copy
        }
    }
}
