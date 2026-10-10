import Foundation
import KeystivoHelperCore

/// Keystivo's privileged helper. Runs as root via launchd (SMAppService.daemon),
/// accepts XPC connections only from the signed Keystivo app, and can do exactly
/// one thing: switch battery charging / the power adapter through known SMC keys.
final class HelperService: NSObject, KeystivoHelperProtocol, @unchecked Sendable {
    private let controller: ChargeController?

    override init() {
        controller = SMC().map(ChargeController.init)
        super.init()
        // A previous instance may have crashed with charging inhibited.
        restoreDefaults()
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(KeystivoHelper.version)
    }

    func setChargingEnabled(_ enabled: Bool, reply: @escaping @Sendable (Bool, String) -> Void) {
        guard let controller else { return reply(false, ChargeControlScheme.unsupported.rawValue) }
        reply(controller.setCharging(enabled), controller.scheme.rawValue)
    }

    func setAdapterEnabled(_ enabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(controller?.setAdapter(enabled) ?? false)
    }

    func setHardwareLimit(_ percent: Int, reply: @escaping @Sendable (Bool) -> Void) {
        reply(controller?.setHardwareLimit(percent) ?? false)
    }

    func status(reply: @escaping @Sendable (Bool, Bool, String) -> Void) {
        reply(controller?.isChargingEnabled ?? true, controller?.isAdapterEnabled ?? true, controller?.scheme.rawValue ?? ChargeControlScheme.unsupported.rawValue)
    }

    /// Safety net: whenever the app disconnects (quit, crash, update), restore
    /// normal charging so the Mac never stays capped without Keystivo running.
    func restoreDefaults() {
        _ = controller?.setAdapter(true)
        _ = controller?.setCharging(true)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(KeystivoHelper.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: KeystivoHelperProtocol.self)
        connection.exportedObject = service
        let service = self.service
        connection.invalidationHandler = { service.restoreDefaults() }
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: KeystivoHelper.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
