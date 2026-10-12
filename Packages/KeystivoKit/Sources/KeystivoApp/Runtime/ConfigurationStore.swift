import AppKit
import Carbon.HIToolbox
import KeystivoAccessibility
import KeystivoAudio
import KeystivoAutomation
import KeystivoClipboard
import KeystivoCore
import KeystivoFiles
import KeystivoInput
import KeystivoLinks
import KeystivoNavigation
import KeystivoPlugins
import KeystivoSearch
import KeystivoSystem
import KeystivoTools
import KeystivoWindows
import Observation

/// Owns the persisted configuration: loading (tolerant of missing keys),
/// debounced atomic saving, backups, and import/export.
@Observable
final class ConfigurationStore {
    var configuration: KeystivoConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            scheduleSave()
            onChange?(oldValue, configuration)
        }
    }

    @ObservationIgnored var onChange: ((KeystivoConfiguration, KeystivoConfiguration) -> Void)?
    @ObservationIgnored private let store: JSONFileStore<KeystivoConfiguration>
    @ObservationIgnored private let saveDebouncer = Debouncer(delay: .milliseconds(600))
    private(set) var isFirstLaunch = false

    init(url: URL = AppPaths.configurationFile) {
        store = JSONFileStore(url: url)
        configuration = KeystivoConfiguration()
        load()
    }

    // MARK: Load / save

    private func load() {
        guard FileManager.default.fileExists(atPath: store.url.path) else {
            isFirstLaunch = true
            configuration = Self.makeDefault()
            saveNow()
            return
        }
        do {
            let data = try Data(contentsOf: store.url)
            let (loaded, repaired) = try Self.decodeRepairing(data)
            configuration = loaded
            if repaired {
                // Some settings were damaged and fell back to defaults; keep the original for reference.
                let backup = store.url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date.now.timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: store.url, to: backup)
                DiagnosticsCenter.shared.record(.warning, module: "Configuration", L("config.error.repaired", backup.lastPathComponent))
            }
        } catch {
            let backup = store.url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date.now.timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: store.url, to: backup)
            DiagnosticsCenter.shared.record(.error, module: "Configuration", L("config.error.corrupt", backup.lastPathComponent), detail: String(describing: error))
            configuration = Self.makeDefault()
        }
    }

    /// Decodes after deep-merging onto the defaults, so keys added in newer
    /// versions (or removed by hand-editing) fall back to default values.
    static func decodeTolerantly(_ data: Data) throws -> KeystivoConfiguration {
        try decodeRepairing(data).configuration
    }

    /// Like ``decodeTolerantly(_:)``, but a damaged part (a wrong type, a broken
    /// list) no longer costs every other setting: each top-level section, and
    /// then each setting inside a damaged section, is kept when it still decodes.
    static func decodeRepairing(_ data: Data) throws -> (configuration: KeystivoConfiguration, repaired: Bool) {
        let defaults = try JSONSerialization.jsonObject(with: JSONFileStore<KeystivoConfiguration>.encoder.encode(KeystivoConfiguration()))
        let loaded = try JSONSerialization.jsonObject(with: data)
        if let configuration = try? decode(deepMerge(defaults, loaded)) {
            return (configuration, false)
        }
        guard let defaultsRoot = defaults as? [String: Any], let loadedRoot = loaded as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var kept = defaultsRoot
        for (key, value) in loadedRoot.sorted(by: { $0.key < $1.key }) {
            var attempt = kept
            attempt[key] = defaultsRoot[key].map { deepMerge($0, value) } ?? value
            if (try? decode(attempt)) != nil {
                kept = attempt
                continue
            }
            // Keep the good settings of a damaged section.
            guard var section = defaultsRoot[key] as? [String: Any], let loadedSection = value as? [String: Any] else { continue }
            for (child, childValue) in loadedSection.sorted(by: { $0.key < $1.key }) {
                var trialSection = section
                trialSection[child] = section[child].map { deepMerge($0, childValue) } ?? childValue
                var trial = kept
                trial[key] = trialSection
                if (try? decode(trial)) != nil { section = trialSection }
            }
            kept[key] = section
        }
        return (try decode(kept), true)
    }

    private static func decode(_ object: Any) throws -> KeystivoConfiguration {
        // `data(withJSONObject:)` raises an Objective-C exception (a crash, not
        // a Swift error) for anything that isn't a JSON container.
        guard JSONSerialization.isValidJSONObject(object) else { throw CocoaError(.coderReadCorrupt) }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONFileStore<KeystivoConfiguration>.decoder.decode(KeystivoConfiguration.self, from: data)
    }

    static func deepMerge(_ base: Any, _ overlay: Any) -> Any {
        guard let baseDict = base as? [String: Any], let overlayDict = overlay as? [String: Any] else { return overlay }
        var result = baseDict
        for (key, value) in overlayDict {
            result[key] = result[key].map { deepMerge($0, value) } ?? value
        }
        return result
    }

    #if DEBUG
    /// Developer tests change settings in memory only.
    @ObservationIgnored var suspendsSaving = false
    #endif

    func scheduleSave() {
        #if DEBUG
        if suspendsSaving { return }
        #endif
        saveDebouncer.schedule { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        #if DEBUG
        if suspendsSaving { return }
        #endif
        do {
            try store.save(configuration)
        } catch {
            DiagnosticsCenter.shared.record(error, module: "Configuration", context: L("config.error.save"))
        }
    }

    // MARK: Import / export ("yapılandırmaları içe ve dışa aktarma")

    nonisolated struct ExportFile: Codable {
        var format = "com.keystivo.configuration"
        var schemaVersion = KeystivoConfiguration.currentSchema
        var exportedAt = Date.now
        var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var sections: [String]
        var configuration: KeystivoConfiguration
    }

    func export(sections: Set<KeystivoConfiguration.Section>) throws -> Data {
        // Unselected sections are written as defaults and ignored on import.
        var partial = KeystivoConfiguration()
        let source = configuration
        for section in sections { Self.copy(section, from: source, to: &partial) }
        let file = ExportFile(sections: sections.map(\.rawValue).sorted(), configuration: partial)
        return try JSONFileStore<ExportFile>.encoder.encode(file)
    }

    func previewImport(_ data: Data) throws -> ExportFile {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any], (dict["format"] as? String) == "com.keystivo.configuration",
              let configObject = dict["configuration"], JSONSerialization.isValidJSONObject(configObject) else {
            throw ActionError.failed(L("config.error.importFormat"))
        }
        let configData = try JSONSerialization.data(withJSONObject: configObject)
        let config = try Self.decodeTolerantly(configData)
        let sections = dict["sections"] as? [String] ?? KeystivoConfiguration.Section.allCases.map(\.rawValue)
        return ExportFile(sections: sections, configuration: config)
    }

    func apply(_ file: ExportFile, sections: Set<KeystivoConfiguration.Section>) {
        backup(reason: "before-import")
        var updated = configuration
        for section in sections where file.sections.contains(section.rawValue) {
            Self.copy(section, from: file.configuration, to: &updated)
        }
        Self.quarantineImported(&updated, keepingTrustFrom: configuration)
        updated.general.hasCompletedOnboarding = true
        configuration = updated
    }

    /// Imported settings never arrive able to run code unreviewed: plugin trust
    /// stays this Mac's own, and shortcuts or folder rules that run scripts or
    /// plugins come in switched off (workflows already import disabled).
    static func quarantineImported(_ config: inout KeystivoConfiguration, keepingTrustFrom current: KeystivoConfiguration) {
        config.plugins.trusted = current.plugins.trusted
        let runsCode: (String) -> Bool = { $0 == "system.runShellScript" || $0 == "system.runAppleScript" || $0.hasPrefix("plugin.") }
        for index in config.hotkeys.indices where config.hotkeys[index].actions.contains(where: { runsCode($0.actionID) }) {
            if !current.hotkeys.contains(config.hotkeys[index]) { config.hotkeys[index].isEnabled = false }
        }
        for index in config.files.folderRules.indices {
            let rule = config.files.folderRules[index]
            let scripted = rule.actions.contains { if case .runShellScript = $0 { true } else { false } }
            if scripted, !current.files.folderRules.contains(rule) { config.files.folderRules[index].isEnabled = false }
        }
    }

    static func copy(_ section: KeystivoConfiguration.Section, from source: KeystivoConfiguration, to target: inout KeystivoConfiguration) {
        switch section {
        case .general: target.general = source.general
        case .hotkeys: target.hotkeys = source.hotkeys
        case .launcher: target.launcher = source.launcher
        case .switcher: target.switcher = source.switcher
        case .windows: target.windows = source.windows
        case .dock: target.dock = source.dock
        case .navigation: target.navigation = source.navigation
        case .audio: target.audio = source.audio
        case .gestures: target.gestures = source.gestures
        case .automation: target.automation = source.automation
        case .clipboard: target.clipboard = source.clipboard
        case .snippets: target.snippets = source.snippets
        case .workspace: target.workspace = source.workspace
        case .system: target.system = source.system
        case .plugins: target.plugins = source.plugins
        case .input: target.input = source.input
        case .menuBar: target.menuBar = source.menuBar
        case .tools: target.tools = source.tools
        case .files: target.files = source.files
        case .links: target.links = source.links
        case .presentation: target.presentation = source.presentation
        case .widgets: target.widgets = source.widgets
        }
    }

    // MARK: Backups

    @discardableResult
    func backup(reason: String) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = AppPaths.backupsDirectory.appendingPathComponent("configuration-\(formatter.string(from: .now))-\(reason).json")
        do {
            try JSONFileStore<KeystivoConfiguration>(url: url).save(configuration)
            pruneBackups(keep: 20)
            return url
        } catch {
            DiagnosticsCenter.shared.record(error, module: "Configuration")
            return nil
        }
    }

    var backups: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AppPaths.backupsDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func restore(backup url: URL) throws {
        let data = try Data(contentsOf: url)
        let restored = try Self.decodeTolerantly(data)
        self.backup(reason: "before-restore")
        configuration = restored
    }

    private func pruneBackups(keep: Int) {
        for url in backups.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }

    func resetToDefaults() {
        backup(reason: "before-reset")
        var fresh = Self.makeDefault()
        fresh.general.hasCompletedOnboarding = true
        fresh.general.language = configuration.general.language
        configuration = fresh
    }

    // MARK: Defaults

    static func makeDefault() -> KeystivoConfiguration {
        var config = KeystivoConfiguration()
        config.hotkeys = defaultHotkeys()
        let work = UserProfile(name: L("profile.default.work"), symbolName: "briefcase.fill", colorName: "blue")
        let personal = UserProfile(name: L("profile.default.personal"), symbolName: "house.fill", colorName: "orange")
        config.workspace.profiles = [work, personal]
        config.workspace.activeProfileID = work.id
        config.workspace.appGroups = [
            AppGroup(name: L("group.default.development"), symbolName: "hammer", bundleIDs: ["com.apple.dt.Xcode", "com.apple.Terminal", "com.microsoft.VSCode"]),
            AppGroup(name: L("group.default.communication"), symbolName: "bubble.left.and.bubble.right", bundleIDs: ["com.apple.mail", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap"]),
        ]
        return config
    }

    static func defaultHotkeys() -> [HotkeyBinding] {
        let ctrlOpt: KeyModifiers = [.control, .option]
        let ctrlOptCmd: KeyModifiers = [.control, .option, .command]
        var bindings: [HotkeyBinding] = [
            HotkeyBinding(KeyCombo(kVK_Space, .option), "launcher.show"),
            HotkeyBinding(KeyCombo(kVK_Tab, .option), "windows.switcher"),
            HotkeyBinding(KeyCombo(kVK_ANSI_Grave, .option), "windows.previous"),
            HotkeyBinding(KeyCombo(kVK_ANSI_V, [.option, .command]), "clipboard.history"),
            HotkeyBinding(KeyCombo(kVK_Space, [.command, .shift]), "navigation.hints"),
            HotkeyBinding(KeyCombo(kVK_ANSI_J, [.command, .shift]), "navigation.scroll"),
            HotkeyBinding(KeyCombo(kVK_ANSI_M, ctrlOpt), "audio.showMixer"),
            HotkeyBinding(KeyCombo(kVK_ANSI_Z, ctrlOpt), "windows.undo"),
        ]
        let snaps: [(Int, KeyModifiers, String)] = [
            (kVK_LeftArrow, ctrlOpt, "leftHalf"), (kVK_RightArrow, ctrlOpt, "rightHalf"),
            (kVK_UpArrow, ctrlOpt, "topHalf"), (kVK_DownArrow, ctrlOpt, "bottomHalf"),
            (kVK_Return, ctrlOpt, "maximize"), (kVK_ANSI_C, ctrlOpt, "center"),
            (kVK_ANSI_D, ctrlOpt, "firstThird"), (kVK_ANSI_F, ctrlOpt, "centerThird"), (kVK_ANSI_G, ctrlOpt, "lastThird"),
            (kVK_ANSI_E, ctrlOpt, "firstTwoThirds"), (kVK_ANSI_T, ctrlOpt, "lastTwoThirds"),
            (kVK_ANSI_U, ctrlOpt, "topLeftQuarter"), (kVK_ANSI_I, ctrlOpt, "topRightQuarter"),
            (kVK_ANSI_J, ctrlOpt, "bottomLeftQuarter"), (kVK_ANSI_K, ctrlOpt, "bottomRightQuarter"),
        ]
        for (key, modifiers, position) in snaps {
            bindings.append(HotkeyBinding(KeyCombo(key, modifiers), "windows.snap.\(position)"))
        }
        bindings.append(HotkeyBinding(KeyCombo(kVK_Delete, ctrlOpt), "windows.restore"))
        bindings.append(HotkeyBinding(KeyCombo(kVK_ANSI_Equal, ctrlOpt), "windows.larger"))
        bindings.append(HotkeyBinding(KeyCombo(kVK_ANSI_Minus, ctrlOpt), "windows.smaller"))
        bindings.append(HotkeyBinding(KeyCombo(kVK_RightArrow, ctrlOptCmd), "windows.display.next"))
        bindings.append(HotkeyBinding(KeyCombo(kVK_LeftArrow, ctrlOptCmd), "windows.display.previous"))
        return bindings
    }
}
