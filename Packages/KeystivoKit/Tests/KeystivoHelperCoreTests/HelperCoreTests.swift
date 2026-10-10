@testable import KeystivoHelperCore
import Testing

@Suite("Charge limit policy")
struct ChargeLimitPolicyTests {
    typealias Policy = ChargeLimitPolicy

    @Test func stopsAtLimit() {
        #expect(Policy.decide(level: 80, limit: 80, hysteresis: 5, chargingEnabled: true, adapterEnabled: true, dischargesAboveLimit: false) == .disableCharging)
        #expect(Policy.decide(level: 85, limit: 80, hysteresis: 5, chargingEnabled: false, adapterEnabled: true, dischargesAboveLimit: false) == .none)
    }

    @Test func sailsInsideTheBand() {
        // Between 75 and 80 nothing changes, so the battery doesn't micro-cycle.
        #expect(Policy.decide(level: 77, limit: 80, hysteresis: 5, chargingEnabled: false, adapterEnabled: true, dischargesAboveLimit: false) == .none)
        #expect(Policy.decide(level: 77, limit: 80, hysteresis: 5, chargingEnabled: true, adapterEnabled: true, dischargesAboveLimit: false) == .none)
        #expect(Policy.decide(level: 74, limit: 80, hysteresis: 5, chargingEnabled: false, adapterEnabled: true, dischargesAboveLimit: false) == .enableCharging)
    }

    @Test func dischargesWhenRequested() {
        #expect(Policy.decide(level: 95, limit: 80, hysteresis: 5, chargingEnabled: false, adapterEnabled: true, dischargesAboveLimit: true) == .dischargeOnAdapter)
        // Reached the limit: reconnect the adapter but keep charging off.
        #expect(Policy.decide(level: 80, limit: 80, hysteresis: 5, chargingEnabled: false, adapterEnabled: false, dischargesAboveLimit: true) == .disableCharging)
    }

    @Test func fullLimitRestoresNormalCharging() {
        #expect(Policy.decide(level: 50, limit: 100, hysteresis: 5, chargingEnabled: false, adapterEnabled: true, dischargesAboveLimit: false) == .enableCharging)
        #expect(Policy.decide(level: 50, limit: 100, hysteresis: 5, chargingEnabled: true, adapterEnabled: true, dischargesAboveLimit: false) == .none)
    }

    @Test func limitIsClamped() {
        #expect(Policy.decide(level: 15, limit: 5, hysteresis: 0, chargingEnabled: true, adapterEnabled: true, dischargesAboveLimit: false) == .none)
        #expect(Policy.decide(level: 21, limit: 5, hysteresis: 0, chargingEnabled: true, adapterEnabled: true, dischargesAboveLimit: false) == .disableCharging)
    }

    @Test func smcKeyCodes() {
        #expect(SMC.code("CHTE")?.count == 4)
        #expect(SMC.code("TOO LONG") == nil)
    }

    /// Read-only probe: the SMC is reachable without privileges on real Macs.
    @Test func smcIsReadable() {
        guard let smc = SMC() else { return }
        // "#KEY" holds the number of SMC keys on every Mac.
        #expect(smc.read("#KEY") != nil)
    }
}
