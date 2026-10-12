import Foundation
@testable import KeystivoCore
import Testing

@Suite("Crash guards: core")
struct CoreCrashGuardTests {
    @Test func safeIntNeverTraps() {
        #expect(Double.nan.safeInt == 0)
        #expect(Double.infinity.safeInt > 0)
        #expect((-Double.infinity).safeInt < 0)
        #expect(1e300.safeInt > 0)
        #expect(Float(12.7).safeInt == 12)
        #expect((-3.9).safeInt == -3)
    }

    /// Numbers from imported workflows or hand-edited settings ("inf", "1e30").
    @Test func actionArgumentIntsNeverTrap() {
        let arguments = ActionArguments(["a": .string("inf"), "b": .string("nan"), "c": .number(1e300), "d": .number(42)])
        #expect(arguments.int("a") != nil)
        #expect(arguments.int("b") == 0)
        #expect(arguments.int("c") != nil)
        #expect(arguments.int("d") == 42)
    }
}
