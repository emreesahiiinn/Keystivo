import AudioToolbox
import CoreAudio
import Foundation

nonisolated public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String
    public var description: String { "\(operation) failed (\(status.fourCharCode))" }
}

nonisolated extension OSStatus {
    var fourCharCode: String {
        let value = UInt32(bitPattern: self)
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "'" + String(decoding: bytes, as: UTF8.self) + "'" }
        return String(self)
    }
}

/// Typed helpers over the AudioObject property API.
nonisolated enum AudioProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, default value: T) throws -> T {
        var address = address
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "get \(address.mSelector)") }
        return result
    }

    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectSetPropertyData(object, &address, 0, nil, size, &value)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "set \(address.mSelector)") }
    }

    static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of type: T.Type, zero: T) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: zero, count: count)
        // Ask for exactly what the buffer holds, never a partial element more.
        size = UInt32(count * MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
