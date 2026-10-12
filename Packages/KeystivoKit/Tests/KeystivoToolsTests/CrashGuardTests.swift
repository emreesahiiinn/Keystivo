import Foundation
@testable import KeystivoTools
import Testing

@Suite("Crash guards: tools")
struct ToolsCrashGuardTests {
    /// A wrapped 32-bit counter used to produce ~1.8e19 B/s, which trapped in Int64(…).
    @Test func rateNeverTraps() {
        for value in [1.8e19, 9.3e18, .infinity, -.infinity, .nan, -5, 0, 1536] {
            #expect(SystemMonitor.rate(value).hasSuffix("/s"))
        }
    }
}
