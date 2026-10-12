import AudioToolbox
import CoreAudio
import Foundation
import KeystivoCore
import Observation

nonisolated public struct AudioDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let hasOutput: Bool
    public let hasInput: Bool
    public let transport: UInt32

    public var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeBuiltIn: hasInput && !hasOutput ? "mic" : "laptopcomputer"
        case kAudioDeviceTransportTypeUSB: "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: "waveform"
        default: hasInput && !hasOutput ? "mic" : "speaker.wave.2"
        }
    }
}

/// System audio devices, default routing, volume and mute — all driven by
/// Core Audio property listeners (no polling).
@Observable
public final class AudioDeviceManager {
    public static let shared = AudioDeviceManager()

    public private(set) var outputDevices: [AudioDevice] = []
    public private(set) var inputDevices: [AudioDevice] = []
    public private(set) var defaultOutput: AudioDevice?
    public private(set) var defaultInput: AudioDevice?
    public private(set) var outputVolume: Float = 0
    public private(set) var outputMuted = false
    public private(set) var inputVolume: Float = 0
    public private(set) var inputMuted = false

    /// Fired after the default output device changes (per-app taps must rebuild).
    @ObservationIgnored public var onDefaultOutputChange: (@MainActor (AudioDevice?) -> Void)?
    @ObservationIgnored public var onDevicesChange: (@MainActor () -> Void)?

    @ObservationIgnored private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var savedInputVolume: Float?
    @ObservationIgnored private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        reloadDevices()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            let address = AudioProperty.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.systemChanged(selector) }
            }
            var mutableAddress = address
            if AudioObjectAddPropertyListenerBlock(system, &mutableAddress, .main, block) == noErr {
                systemListeners.append((address, block))
            }
        }
    }

    private func systemChanged(_ selector: AudioObjectPropertySelector) {
        let previousOutput = defaultOutput?.id
        reloadDevices()
        if selector == kAudioHardwarePropertyDevices { onDevicesChange?() }
        if defaultOutput?.id != previousOutput { onDefaultOutputChange?(defaultOutput) }
    }

    // MARK: Enumeration

    public func reloadDevices() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids = AudioProperty.array(system, AudioProperty.address(kAudioHardwarePropertyDevices), of: AudioObjectID.self, zero: 0)
        let devices = ids.compactMap(Self.makeDevice)
            .filter { !$0.name.hasPrefix("Keystivo-") && !$0.uid.hasPrefix("com.keystivo.") }
        outputDevices = devices.filter(\.hasOutput)
        inputDevices = devices.filter(\.hasInput)
        let outputID = (try? AudioProperty.get(system, AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(0))) ?? 0
        let inputID = (try? AudioProperty.get(system, AudioProperty.address(kAudioHardwarePropertyDefaultInputDevice), default: AudioObjectID(0))) ?? 0
        defaultOutput = devices.first { $0.id == outputID }
        defaultInput = devices.first { $0.id == inputID }
        observeDefaultDevices()
        refreshLevels()
    }

    nonisolated static func makeDevice(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = AudioProperty.string(id, AudioProperty.address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = AudioProperty.string(id, AudioProperty.address(kAudioObjectPropertyName)) ?? uid
        let transport = (try? AudioProperty.get(id, AudioProperty.address(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
        func hasStreams(_ scope: AudioObjectPropertyScope) -> Bool {
            var address = AudioProperty.address(kAudioDevicePropertyStreams, scope: scope)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
        }
        return AudioDevice(id: id, uid: uid, name: name, hasOutput: hasStreams(kAudioObjectPropertyScopeOutput),
                           hasInput: hasStreams(kAudioObjectPropertyScopeInput), transport: transport)
    }

    private func observeDefaultDevices() {
        for (device, address, block) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
        deviceListeners.removeAll()
        let targets: [(AudioDevice?, AudioObjectPropertyScope)] = [(defaultOutput, kAudioObjectPropertyScopeOutput), (defaultInput, kAudioObjectPropertyScopeInput)]
        for (device, scope) in targets {
            guard let device else { continue }
            for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                var address = AudioProperty.address(selector, scope: scope)
                guard AudioObjectHasProperty(device.id, &address) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refreshLevels() }
                }
                if AudioObjectAddPropertyListenerBlock(device.id, &address, .main, block) == noErr {
                    deviceListeners.append((device.id, address, block))
                }
            }
        }
    }

    public func refreshLevels() {
        if let output = defaultOutput {
            outputVolume = volume(of: output.id, scope: kAudioObjectPropertyScopeOutput) ?? 0
            outputMuted = mute(of: output.id, scope: kAudioObjectPropertyScopeOutput) ?? false
        }
        if let input = defaultInput {
            inputVolume = volume(of: input.id, scope: kAudioObjectPropertyScopeInput) ?? 0
            inputMuted = mute(of: input.id, scope: kAudioObjectPropertyScopeInput) ?? (inputVolume == 0)
        }
    }

    // MARK: Routing

    public func setDefaultOutput(uid: String) throws {
        guard let device = outputDevices.first(where: { $0.uid == uid }) else { throw ActionError.notAvailable(L("audio.error.deviceMissing")) }
        let system = AudioObjectID(kAudioObjectSystemObject)
        try AudioProperty.set(system, AudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice), device.id)
        // Keep alerts/system sounds on the same device, as users expect.
        try? AudioProperty.set(system, AudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice), device.id)
    }

    public func setDefaultInput(uid: String) throws {
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { throw ActionError.notAvailable(L("audio.error.deviceMissing")) }
        try AudioProperty.set(AudioObjectID(kAudioObjectSystemObject), AudioProperty.address(kAudioHardwarePropertyDefaultInputDevice), device.id)
    }

    /// Cycles to the next output device.
    public func cycleOutput() throws {
        guard !outputDevices.isEmpty else { return }
        let index = outputDevices.firstIndex { $0.id == defaultOutput?.id } ?? -1
        try setDefaultOutput(uid: outputDevices[(index + 1) % outputDevices.count].uid)
    }

    // MARK: Volume

    public func setOutputVolume(_ value: Float) {
        guard let device = defaultOutput else { return }
        let clamped = min(max(value, 0), 1)
        setVolume(clamped, of: device.id, scope: kAudioObjectPropertyScopeOutput)
        if clamped > 0, outputMuted { setOutputMuted(false) }
        refreshLevels()
    }

    public func adjustOutputVolume(by delta: Float) {
        setOutputVolume(outputVolume + delta)
    }

    public func setOutputMuted(_ muted: Bool) {
        guard let device = defaultOutput else { return }
        try? AudioProperty.set(device.id, AudioProperty.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput), UInt32(muted ? 1 : 0))
        refreshLevels()
    }

    public func toggleOutputMute() { setOutputMuted(!outputMuted) }

    // MARK: Microphone

    public func setInputMuted(_ muted: Bool) {
        guard let device = defaultInput else { return }
        let address = AudioProperty.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        if AudioProperty.has(device.id, address), AudioProperty.isSettable(device.id, address) {
            try? AudioProperty.set(device.id, address, UInt32(muted ? 1 : 0))
        } else if muted {
            // Many built-in mics have no mute control; fall back to zero gain.
            savedInputVolume = volume(of: device.id, scope: kAudioObjectPropertyScopeInput)
            setVolume(0, of: device.id, scope: kAudioObjectPropertyScopeInput)
        } else {
            setVolume(savedInputVolume ?? 0.75, of: device.id, scope: kAudioObjectPropertyScopeInput)
        }
        refreshLevels()
        inputMuted = muted
    }

    public func toggleInputMute() { setInputMuted(!inputMuted) }

    public func setInputVolume(_ value: Float) {
        guard let device = defaultInput else { return }
        setVolume(min(max(value, 0), 1), of: device.id, scope: kAudioObjectPropertyScopeInput)
        refreshLevels()
    }

    // MARK: Low level

    private func volume(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        let virtual = AudioProperty.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        // Drivers (virtual devices especially) can report anything; keep it a sane 0…1.
        if AudioProperty.has(device, virtual), let value = try? AudioProperty.get(device, virtual, default: Float32(0)) {
            return min(max(value.finite(or: 0), 0), 1)
        }
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            let address = AudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            if AudioProperty.has(device, address), let value = try? AudioProperty.get(device, address, default: Float32(0)) {
                return min(max(value.finite(or: 0), 0), 1)
            }
        }
        return nil
    }

    private func setVolume(_ value: Float, of device: AudioObjectID, scope: AudioObjectPropertyScope) {
        let virtual = AudioProperty.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        if AudioProperty.isSettable(device, virtual), (try? AudioProperty.set(device, virtual, Float32(value))) != nil {
            return
        }
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            let address = AudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            if AudioProperty.isSettable(device, address) { try? AudioProperty.set(device, address, Float32(value)) }
        }
    }

    private func mute(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool? {
        let address = AudioProperty.address(kAudioDevicePropertyMute, scope: scope)
        guard AudioProperty.has(device, address), let value = try? AudioProperty.get(device, address, default: UInt32(0)) else { return nil }
        return value != 0
    }
}
