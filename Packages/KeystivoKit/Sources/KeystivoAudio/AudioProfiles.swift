import Foundation
import KeystivoCore

/// A named audio setup: devices, levels and per-app mix ("uygulama ses profilleri").
nonisolated public struct AudioProfile: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var name: String
    public var symbolName = "slider.horizontal.3"
    public var outputDeviceUID: String?
    public var inputDeviceUID: String?
    public var outputVolume: Float?
    public var outputMuted: Bool?
    public var inputMuted: Bool?
    /// Replaces the per-app mix entirely when set.
    public var appSettings: [String: AppAudioSetting]?

    public init(name: String) { self.name = name }
}

public enum AudioProfileApplier {
    /// Applies every field the profile defines; unspecified fields are left alone.
    public static func apply(_ profile: AudioProfile, devices: AudioDeviceManager = .shared, apps: AppAudioController = .shared) {
        if let uid = profile.outputDeviceUID { try? devices.setDefaultOutput(uid: uid) }
        if let uid = profile.inputDeviceUID { try? devices.setDefaultInput(uid: uid) }
        if let volume = profile.outputVolume { devices.setOutputVolume(volume) }
        if let muted = profile.outputMuted { devices.setOutputMuted(muted) }
        if let muted = profile.inputMuted { devices.setInputMuted(muted) }
        if let mix = profile.appSettings {
            apps.settings = mix.filter { !$0.value.isDefault }
            apps.refresh()
        }
    }

    /// Snapshot of the current audio state as a new profile.
    public static func capture(name: String, devices: AudioDeviceManager = .shared, apps: AppAudioController = .shared) -> AudioProfile {
        var profile = AudioProfile(name: name)
        profile.outputDeviceUID = devices.defaultOutput?.uid
        profile.inputDeviceUID = devices.defaultInput?.uid
        profile.outputVolume = devices.outputVolume
        profile.outputMuted = devices.outputMuted
        profile.inputMuted = devices.inputMuted
        profile.appSettings = apps.settings
        return profile
    }
}
