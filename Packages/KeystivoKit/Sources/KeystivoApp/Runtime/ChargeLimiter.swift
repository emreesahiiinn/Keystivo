import AppKit
import KeystivoCore
import KeystivoHelperCore
import KeystivoSystem
import Observation
import ServiceManagement

nonisolated struct ChargeLimitSettings: Codable, Hashable, Sendable {
    var isEnabled = false
    /// Maximum charge level (AlDente-style).
    var limit = 80
    /// Charging resumes only below `limit - sailingRange` to avoid micro-cycles.
    var sailingRange = 5
    /// While plugged in above the limit, run on battery until the limit is reached.
    var dischargesAboveLimit = false
}

/// Battery charge limiting through Keystivo's privileged helper ("AlDente").
///
/// The helper runs as a launchd daemon installed with SMAppService after the
/// user approves it, and only exposes "charging on/off" and "adapter on/off".
/// If Keystivo quits or crashes, the helper restores normal charging.
@Observable
final class ChargeLimiter {
    enum HelperState: Equatable {
        case unsupported
        case notInstalled
        case requiresApproval
        case installed
        case failed(String)
    }

    private(set) var helperState: HelperState = .notInstalled
    private(set) var scheme: ChargeControlScheme?
    private(set) var isChargingEnabled = true
    private(set) var isAdapterEnabled = true
    private(set) var isToppingUp = false
    var settings = ChargeLimitSettings() {
        didSet { if settings != oldValue { evaluate() } }
    }

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var appliedHardwareLimit: Int?
    @ObservationIgnored private let service = SMAppService.daemon(plistName: KeystivoHelper.launchdPlistName)

    var hasBattery: Bool { PowerMonitor.shared.hasBattery }

    func start() {
        refreshHelperState()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    func refreshHelperState() {
        guard hasBattery else { helperState = .unsupported; return }
        switch service.status {
        case .enabled: helperState = .installed
        case .requiresApproval: helperState = .requiresApproval
        case .notRegistered, .notFound: helperState = .notInstalled
        @unknown default: helperState = .notInstalled
        }
        if helperState == .installed { Task { await refreshStatus() } }
    }

    // MARK: Helper lifecycle

    func installHelper() {
        do {
            try service.register()
        } catch {
            if service.status != .requiresApproval {
                helperState = .failed(error.localizedDescription)
                DiagnosticsCenter.shared.record(error, module: "Battery", context: L("battery.error.install"))
                return
            }
        }
        refreshHelperState()
        if helperState == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstallHelper() async {
        await send(.enableCharging)
        if let limit = appliedHardwareLimit, limit < 100 { _ = await call { proxy, done in proxy.setHardwareLimit(100) { done($0) } } }
        connection?.invalidate()
        connection = nil
        try? await service.unregister()
        refreshHelperState()
    }

    // MARK: Enforcement

    /// Re-evaluates the policy; called on power changes, wake and settings changes.
    func evaluate() {
        guard hasBattery, helperState == .installed else { return }
        let monitor = PowerMonitor.shared
        guard let level = monitor.batteryLevel else { return }
        // While we bypass the adapter macOS reports battery power, but the charger is still connected.
        let pluggedIn = monitor.isOnAC || !isAdapterEnabled
        if isToppingUp, level >= 100 || !pluggedIn { isToppingUp = false }
        let limit = !settings.isEnabled || isToppingUp ? 100 : settings.limit
        if scheme == .bclm {
            guard appliedHardwareLimit != limit else { return }
            appliedHardwareLimit = limit
            Task { _ = await call { proxy, done in proxy.setHardwareLimit(limit) { done($0) } } }
            return
        }
        let command = ChargeLimitPolicy.decide(
            level: level, limit: limit, hysteresis: settings.sailingRange,
            chargingEnabled: isChargingEnabled, adapterEnabled: isAdapterEnabled,
            dischargesAboveLimit: settings.dischargesAboveLimit && pluggedIn
        )
        guard command != .none else { return }
        Task { await send(command) }
    }

    /// Charges to 100% once (e.g. before a trip), then returns to the limit.
    func topUp() {
        isToppingUp = true
        evaluate()
    }

    /// Restores normal charging (app quit). The helper also does this when we disconnect.
    func shutdown() {
        guard helperState == .installed, let connection, !(isChargingEnabled && isAdapterEnabled) else { return }
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in } as? any KeystivoHelperProtocol
        proxy?.setAdapterEnabled(true) { _ in }
        proxy?.setChargingEnabled(true) { _, _ in }
        connection.invalidate()
    }

    private func send(_ command: ChargeLimitPolicy.Command) async {
        switch command {
        case .enableCharging:
            _ = await call { proxy, done in proxy.setAdapterEnabled(true) { done($0) } }
            _ = await call { proxy, done in proxy.setChargingEnabled(true) { ok, _ in done(ok) } }
        case .disableCharging:
            _ = await call { proxy, done in proxy.setAdapterEnabled(true) { done($0) } }
            _ = await call { proxy, done in proxy.setChargingEnabled(false) { ok, _ in done(ok) } }
        case .dischargeOnAdapter:
            _ = await call { proxy, done in proxy.setChargingEnabled(false) { ok, _ in done(ok) } }
            _ = await call { proxy, done in proxy.setAdapterEnabled(false) { done($0) } }
        case .none:
            break
        }
        await refreshStatus()
    }

    private func refreshStatus() async {
        let status: (Bool, Bool, String)? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = proxy(onError: { once.resume(nil) }) else {
                once.resume(nil)
                return
            }
            proxy.status { charging, adapter, scheme in once.resume((charging, adapter, scheme)) }
        }
        guard let status else { return }
        isChargingEnabled = status.0
        isAdapterEnabled = status.1
        scheme = ChargeControlScheme(rawValue: status.2)
        if scheme == .unsupported { helperState = .unsupported }
    }

    // MARK: XPC

    private func call(_ body: @escaping (any KeystivoHelperProtocol, @escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let proxy = proxy(onError: { once.resume(false) }) else {
                once.resume(false)
                return
            }
            body(proxy) { once.resume($0) }
        }
    }

    private func proxy(onError: @escaping @Sendable () -> Void) -> (any KeystivoHelperProtocol)? {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: KeystivoHelper.machServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: (any KeystivoHelperProtocol).self)
            // Only talk to our own helper binary.
            connection.setCodeSigningRequirement("identifier \"com.keystivo.Keystivo.helper\"")
            // The helper restores normal charging when a connection ends; reconnect and re-apply.
            connection.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.connection === connection else { return }
                        self.connection = nil
                        self.isChargingEnabled = true
                        self.isAdapterEnabled = true
                        self.appliedHardwareLimit = nil
                    }
                }
            }
            connection.interruptionHandler = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self?.evaluate() } }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DiagnosticsCenter.shared.record(.warning, module: "Battery", L("battery.error.helper"), detail: error.localizedDescription)
                }
            }
            onError()
        } as? any KeystivoHelperProtocol
    }
}

/// Guards a continuation against being resumed twice (reply + error handler).
nonisolated private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
