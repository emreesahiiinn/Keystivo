import Foundation

/// Identity of Keystivo's privileged helper (shared by app and helper).
public enum KeystivoHelper {
    public static let machServiceName = "com.keystivo.Keystivo.helper"
    public static let launchdPlistName = "com.keystivo.Keystivo.helper.plist"
    public static let version = "1.0"
    /// Only the Keystivo app may talk to the helper.
    public static let clientRequirement = "identifier \"com.keystivo.Keystivo\""
}

/// XPC interface of the privileged helper. Deliberately tiny: it can only
/// toggle charging and the adapter through known SMC keys — never arbitrary writes.
@objc public protocol KeystivoHelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void)
    /// Returns (success, scheme rawValue).
    func setChargingEnabled(_ enabled: Bool, reply: @escaping @Sendable (Bool, String) -> Void)
    func setAdapterEnabled(_ enabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
    /// Intel only: hardware charge ceiling.
    func setHardwareLimit(_ percent: Int, reply: @escaping @Sendable (Bool) -> Void)
    /// Returns (chargingEnabled, adapterEnabled, scheme rawValue).
    func status(reply: @escaping @Sendable (Bool, Bool, String) -> Void)
}

/// Pure charge-limit decision logic, unit-tested independently of hardware.
public enum ChargeLimitPolicy {
    public enum Command: Equatable, Sendable {
        case enableCharging
        case disableCharging
        case dischargeOnAdapter
        case none
    }

    /// - Parameters:
    ///   - level: current battery percentage.
    ///   - limit: target maximum.
    ///   - hysteresis: charging resumes only below `limit - hysteresis` (sailing mode).
    ///   - chargingEnabled: current charging state.
    ///   - dischargesAboveLimit: actively drain to the limit while plugged in.
    public static func decide(level: Int, limit: Int, hysteresis: Int, chargingEnabled: Bool, adapterEnabled: Bool, dischargesAboveLimit: Bool) -> Command {
        let limit = max(20, min(100, limit))
        if limit >= 100 { return chargingEnabled && adapterEnabled ? .none : .enableCharging }
        if dischargesAboveLimit, level > limit + 1 {
            return adapterEnabled ? .dischargeOnAdapter : .none
        }
        if level >= limit {
            return chargingEnabled || !adapterEnabled ? .disableCharging : .none
        }
        if level < limit - max(0, hysteresis) {
            return chargingEnabled && adapterEnabled ? .none : .enableCharging
        }
        // Inside the sailing band: keep the current state, but never stay on battery.
        return adapterEnabled ? .none : .disableCharging
    }
}
