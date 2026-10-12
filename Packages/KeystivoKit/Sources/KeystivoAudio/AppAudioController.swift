import AppKit
import AudioToolbox
import CoreAudio
import KeystivoCore
import Observation

/// Persisted per-app audio preference.
nonisolated public struct AppAudioSetting: Codable, Hashable, Sendable {
    public var volume: Float
    public var muted: Bool
    /// Plays this app on a specific output (nil: the system output), SoundSource-style.
    public var outputDeviceUID: String?

    public init(volume: Float = 1, muted: Bool = false, outputDeviceUID: String? = nil) {
        self.volume = volume
        self.muted = muted
        self.outputDeviceUID = outputDeviceUID
    }

    /// Default settings need no tap (zero CPU cost).
    public var isDefault: Bool { abs(volume - 1) < 0.005 && !muted && outputDeviceUID == nil }
    public var effectiveGain: Float { muted ? 0 : volume }
}

/// An application currently known to Core Audio.
nonisolated public struct AppAudioEntry: Identifiable, Hashable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let pid: pid_t
    public var processObjectIDs: [AudioObjectID]
    public var isPlaying: Bool
}

/// Per-app volume, mute and peak meters ("uygulama bazlı ses").
@Observable
public final class AppAudioController {
    public static let shared = AppAudioController()

    public private(set) var entries: [AppAudioEntry] = []
    public var settings: [String: AppAudioSetting] = [:] {
        didSet {
            onSettingsChange?(settings)
            // Profiles, imports and Settings change levels too, not only the mixer.
            if settings != oldValue { syncTaps() }
        }
    }
    /// Master switch; when off no taps exist and Keystivo touches no app audio.
    public var isEnabled = true {
        didSet { syncTaps() }
    }
    /// Power saving: drop volume adjustments but keep muted apps muted.
    public var keepsOnlyMutes = false {
        didSet { if keepsOnlyMutes != oldValue { syncTaps() } }
    }
    public private(set) var lastError: String?
    public static var isSupported: Bool { true }

    @ObservationIgnored public var onSettingsChange: (([String: AppAudioSetting]) -> Void)?
    @ObservationIgnored private var taps: [String: ProcessTap] = [:]
    @ObservationIgnored private var listenerBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var started = false
    /// When each app last started or stopped playing, so a short pause between
    /// tracks doesn't make it vanish from the mixer.
    @ObservationIgnored private var lastPlaying: [String: Date] = [:]
    /// How long an app stays in the mixer after it stops playing.
    public static let recentWindow: TimeInterval = 30
    @ObservationIgnored private let refreshDebouncer = Debouncer(delay: .milliseconds(250))

    public init() {}

    public func start(devices: AudioDeviceManager = .shared) {
        guard !started else { return }
        started = true
        let previous = devices.onDefaultOutputChange
        devices.onDefaultOutputChange = { [weak self] device in
            previous?(device)
            self?.rebuildAllTaps()
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr {
            listenerBlocks.append((system, address, block))
        }
        refresh()
    }

    private func scheduleRefresh() {
        refreshDebouncer.schedule { [weak self] in self?.refresh() }
    }

    // MARK: Discovery

    public func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let objects = AudioProperty.array(system, AudioProperty.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self, zero: 0)
        var grouped: [String: AppAudioEntry] = [:]
        for object in objects {
            guard let pid = try? AudioProperty.get(object, AudioProperty.address(kAudioProcessPropertyPID), default: pid_t(0)), pid > 0, pid != getpid() else { continue }
            let running = (try? AudioProperty.get(object, AudioProperty.address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0
            guard let app = Self.owningApplication(pid: pid), let bundleID = app.bundleIdentifier else { continue }
            var entry = grouped[bundleID] ?? AppAudioEntry(
                bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier,
                processObjectIDs: [], isPlaying: false
            )
            entry.processObjectIDs.append(object)
            entry.isPlaying = entry.isPlaying || running != 0
            grouped[bundleID] = entry
        }
        // Listen for play/stop changes on each process object.
        observeRunningState(objects)
        let wasPlaying = Set(entries.filter(\.isPlaying).map(\.bundleID))
        let now = Date.now
        for entry in grouped.values where entry.isPlaying || wasPlaying.contains(entry.bundleID) {
            lastPlaying[entry.bundleID] = now
        }
        entries = grouped.values.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        syncTaps()
    }

    private func observeRunningState(_ objects: [AudioObjectID]) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (object, address, block) in listenerBlocks where object != system {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listenerBlocks.removeAll { $0.0 != system }
        for object in objects {
            var address = AudioProperty.address(kAudioProcessPropertyIsRunningOutput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                listenerBlocks.append((object, address, block))
            }
        }
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    /// Maps helper processes (browser renderers, WebKit GPU process) to the app
    /// the user sees, using the system's responsibility attribution.
    static func owningApplication(pid: pid_t) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
        if let responsiblePID, case let owner = responsiblePID(pid), owner > 0, owner != pid,
           let app = NSRunningApplication(processIdentifier: owner), app.activationPolicy == .regular {
            return app
        }
        guard let helper = NSRunningApplication(processIdentifier: pid), let bundleID = helper.bundleIdentifier else { return nil }
        var components = bundleID.split(separator: ".")
        while components.count > 2 {
            components.removeLast()
            let candidate = components.joined(separator: ".")
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first(where: { $0.activationPolicy == .regular }) {
                return app
            }
        }
        return nil
    }

    // MARK: Control

    public func setting(for bundleID: String) -> AppAudioSetting { settings[bundleID] ?? AppAudioSetting() }

    /// Apps worth showing in a mixer: playing now, playing until moments ago,
    /// or with a custom level. Apps that merely opened an audio connection at
    /// some point (most apps do) are left out.
    public func audibleEntries(at date: Date = .now) -> [AppAudioEntry] {
        entries.filter { entry in
            entry.isPlaying
                || !setting(for: entry.bundleID).isDefault
                || lastPlaying[entry.bundleID].map { date.timeIntervalSince($0) < Self.recentWindow } == true
        }
    }

    public func setVolume(_ volume: Float, for bundleID: String) {
        var setting = setting(for: bundleID)
        setting.volume = min(max(volume, 0), 1.5)
        if setting.volume > 0 { setting.muted = false }
        store(setting, for: bundleID)
    }

    public func adjustVolume(by delta: Float, for bundleID: String) {
        setVolume(setting(for: bundleID).volume + delta, for: bundleID)
    }

    public func setMuted(_ muted: Bool, for bundleID: String) {
        var setting = setting(for: bundleID)
        setting.muted = muted
        store(setting, for: bundleID)
    }

    public func toggleMute(for bundleID: String) {
        setMuted(!setting(for: bundleID).muted, for: bundleID)
    }

    /// nil sends the app back to the system output.
    public func setOutputDevice(_ uid: String?, for bundleID: String) {
        var setting = setting(for: bundleID)
        setting.outputDeviceUID = uid
        store(setting, for: bundleID)
    }

    public func reset(_ bundleID: String) { store(AppAudioSetting(), for: bundleID) }

    public func resetAll() {
        settings = [:]
        syncTaps()
    }

    private func store(_ setting: AppAudioSetting, for bundleID: String) {
        // The settings observer applies the new level (and creates or removes the tap).
        if setting.isDefault { settings[bundleID] = nil } else { settings[bundleID] = setting }
    }

    /// Recent peak level (0…1) for meters; resets on read.
    public func takePeak(for bundleID: String) -> Float {
        taps[bundleID]?.levels.takePeak() ?? 0
    }

    @ObservationIgnored private var meterLevels: [String: (level: Float, read: Date)] = [:]

    /// Meter level with a smooth fall-off. Shared by every open mixer, so two
    /// views reading at once don't steal each other's peaks.
    public func meterLevel(for bundleID: String) -> Float {
        let previous = meterLevels[bundleID] ?? (0, .distantPast)
        let now = Date.now
        guard now.timeIntervalSince(previous.read) >= 0.04 else { return previous.level }
        let peak = takePeak(for: bundleID)
        let level = max(peak, previous.level * 0.82)
        meterLevels[bundleID] = (level < 0.005 ? 0 : level, now)
        return level
    }

    public func hasActiveTap(_ bundleID: String) -> Bool { taps[bundleID] != nil }

    // MARK: Taps

    /// The app's chosen output if it's connected, else the system output.
    private func outputDevice(for bundleID: String) -> AudioDevice? {
        let devices = AudioDeviceManager.shared
        if let uid = setting(for: bundleID).outputDeviceUID, let device = devices.outputDevices.first(where: { $0.uid == uid }) {
            return device
        }
        return devices.defaultOutput
    }

    private func syncTaps() {
        guard AudioDeviceManager.shared.defaultOutput != nil else { return }
        var wanted: [String: AppAudioEntry] = [:]
        if isEnabled {
            for entry in entries where !setting(for: entry.bundleID).isDefault && (!keepsOnlyMutes || setting(for: entry.bundleID).muted) {
                wanted[entry.bundleID] = entry
            }
        }
        for (bundleID, tap) in taps {
            let entry = wanted[bundleID]
            if entry == nil || Set(entry!.processObjectIDs) != Set(tap.processObjectIDs) || tap.outputUID != outputDevice(for: bundleID)?.uid {
                tap.invalidate()
                taps[bundleID] = nil
            } else {
                tap.gain = setting(for: bundleID).effectiveGain
            }
        }
        for (bundleID, entry) in wanted where taps[bundleID] == nil {
            guard let output = outputDevice(for: bundleID) else { continue }
            do {
                taps[bundleID] = try ProcessTap(
                    bundleID: bundleID, processObjectIDs: entry.processObjectIDs,
                    outputDevice: output, gain: setting(for: bundleID).effectiveGain
                )
                lastError = nil
                PermissionCenter.shared.noteOutcome(.audioCapture, granted: true)
            } catch {
                lastError = String(describing: error)
                PermissionCenter.shared.noteOutcome(.audioCapture, granted: false)
                DiagnosticsCenter.shared.record(.error, module: "Audio", L("audio.error.tap", entry.name), detail: String(describing: error))
            }
        }
    }

    private func rebuildAllTaps() {
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        syncTaps()
    }

    /// Tears down every tap (app quit). Apps return to normal output instantly.
    public func shutdown() {
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }
}
