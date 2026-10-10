import CSMC
import Foundation

/// Swift wrapper over the AppleSMC user client.
public final class SMC: @unchecked Sendable {
    private let connection: io_connect_t
    private let lock = NSLock()

    public init?() {
        let connection = KSSMCOpen()
        guard connection != 0 else { return nil }
        self.connection = connection
    }

    deinit { KSSMCClose(connection) }

    public func keyInfo(_ key: String) -> KSSMCKeyInfo? {
        guard let code = Self.code(key) else { return nil }
        return lock.withLock {
            var info = KSSMCKeyInfo()
            return code.withUnsafeBufferPointer { KSSMCGetKeyInfo(connection, $0.baseAddress!, &info) } ? info : nil
        }
    }

    public func exists(_ key: String) -> Bool { keyInfo(key) != nil }

    public func read(_ key: String) -> [UInt8]? {
        guard let code = Self.code(key) else { return nil }
        return lock.withLock {
            var bytes = [UInt8](repeating: 0, count: 32)
            var size: UInt32 = 0
            let ok = code.withUnsafeBufferPointer { keyPointer in
                bytes.withUnsafeMutableBufferPointer { KSSMCRead(connection, keyPointer.baseAddress!, $0.baseAddress!, &size) }
            }
            return ok ? Array(bytes.prefix(Int(size))) : nil
        }
    }

    /// Writes bytes; the size must match the key's declared size exactly.
    @discardableResult
    public func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let code = Self.code(key) else { return false }
        return lock.withLock {
            code.withUnsafeBufferPointer { keyPointer in
                bytes.withUnsafeBufferPointer { KSSMCWrite(connection, keyPointer.baseAddress!, $0.baseAddress!, UInt32(bytes.count)) }
            } == KERN_SUCCESS
        }
    }

    static func code(_ key: String) -> [CChar]? {
        let ascii = Array(key.utf8)
        guard ascii.count == 4 else { return nil }
        return ascii.map { CChar(bitPattern: $0) }
    }
}

/// Which SMC keys control charging on this Mac. Detected at runtime because
/// Apple changed them across firmware generations.
public enum ChargeControlScheme: String, Sendable, Codable {
    /// Apple Silicon, macOS 15+ firmware: CHTE (4 bytes) inhibits charging.
    case chte
    /// Earlier Apple Silicon/Intel T2 firmware: CH0B + CH0C (1 byte each).
    case ch0b
    /// Intel: BCLM sets a hardware charge ceiling directly (percent).
    case bclm
    case unsupported

    public static func detect(_ smc: SMC) -> ChargeControlScheme {
        if smc.keyInfo("CHTE")?.dataSize == 4 { return .chte }
        if smc.keyInfo("CH0B")?.dataSize == 1, smc.keyInfo("CH0C")?.dataSize == 1 { return .ch0b }
        if smc.keyInfo("BCLM")?.dataSize == 1 { return .bclm }
        return .unsupported
    }
}

/// Inhibits/enables battery charging and the power adapter through known keys only.
public struct ChargeController: Sendable {
    public let smc: SMC
    public let scheme: ChargeControlScheme

    public init(smc: SMC) {
        self.smc = smc
        scheme = ChargeControlScheme.detect(smc)
    }

    public var adapterKey: String? {
        if smc.keyInfo("CHIE")?.dataSize == 1 { return "CHIE" }
        if smc.keyInfo("CH0I")?.dataSize == 1 { return "CH0I" }
        return nil
    }

    public func setCharging(_ enabled: Bool) -> Bool {
        switch scheme {
        case .chte:
            return smc.write("CHTE", enabled ? [0, 0, 0, 0] : [1, 0, 0, 0])
        case .ch0b:
            let value: UInt8 = enabled ? 0x00 : 0x02
            return smc.write("CH0B", [value]) && smc.write("CH0C", [value])
        case .bclm:
            // BCLM is a ceiling; "disable" = clamp to the current level is done by the caller via setLimit.
            return smc.write("BCLM", [enabled ? 100 : 0])
        case .unsupported:
            return false
        }
    }

    /// Intel only: hardware-enforced maximum charge percentage.
    public func setHardwareLimit(_ percent: Int) -> Bool {
        guard scheme == .bclm else { return false }
        return smc.write("BCLM", [UInt8(max(20, min(100, percent)))])
    }

    public var isChargingEnabled: Bool? {
        switch scheme {
        case .chte: return smc.read("CHTE").map { $0.first == 0 }
        case .ch0b: return smc.read("CH0B").map { $0.first == 0 }
        case .bclm: return smc.read("BCLM").map { ($0.first ?? 100) >= 100 }
        case .unsupported: return nil
        }
    }

    /// Disables the power adapter so the Mac runs on battery (used to discharge down to the limit).
    public func setAdapter(_ enabled: Bool) -> Bool {
        guard let key = adapterKey else { return false }
        if key == "CHIE" { return smc.write(key, [enabled ? 0x00 : 0x08]) }
        return smc.write(key, [enabled ? 0x00 : 0x01])
    }

    public var isAdapterEnabled: Bool? {
        guard let key = adapterKey, let bytes = smc.read(key) else { return nil }
        return bytes.first == 0
    }
}
