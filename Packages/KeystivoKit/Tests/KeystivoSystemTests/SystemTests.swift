import Foundation
@testable import KeystivoSystem
import Testing

@Suite("System")
struct SystemTests {
    @Test func destructiveCommandsNeedConfirmation() {
        #expect(SystemCommand.shutDown.isDestructive)
        #expect(SystemCommand.emptyTrash.isDestructive)
        #expect(!SystemCommand.lockScreen.isDestructive)
        for command in SystemCommand.allCases {
            #expect(command.titleKey.hasPrefix("system.command."))
            #expect(!command.symbolName.isEmpty)
        }
    }

    @Test func builtInPowerProfilesHaveStableIDs() {
        let ids = PowerProfile.builtIn.map(\.id)
        #expect(ids == ["balanced", "saver", "performance", "presentation"])
        #expect(PowerProfile.builtIn.first { $0.id == "presentation" }?.keepAwake == .display)
    }

    @Test func focusSettingsDefaults() {
        let settings = FocusSettings()
        #expect(settings.defaultMinutes == 25)
        #expect(settings.distractingApps.contains("com.apple.MobileSMS"))
    }

    @Test func shellRunnerReportsFailures() async throws {
        let output = try await SystemCommandRunner.shell("/bin/echo", ["hello"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        await #expect(throws: (any Error).self) { try await SystemCommandRunner.shell("/usr/bin/false", []) }
    }
}
