import Foundation
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

nonisolated enum AppearancePreference: String, Codable, Hashable, Sendable, CaseIterable {
    case system, light, dark
    var titleKey: String { "appearance.\(rawValue)" }
}

nonisolated struct GeneralSettings: Codable, Hashable, Sendable {
    var language = AppLanguage.systemCode
    var launchAtLogin = false
    var showsMenuBarIcon = true
    var showsDockIcon = false
    var showsHUD = true
    var appearance: AppearancePreference = .system
    var hasCompletedOnboarding = false
}

/// A global (or app-scoped) shortcut running a chain of actions ("komut zincirleri").
nonisolated struct HotkeyBinding: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name = ""
    var combo: KeyCombo?
    var actions: [ActionInvocation]
    /// Empty = global. Otherwise registered only while one of these apps is frontmost.
    var appBundleIDs: [String] = []
    var profileIDs: [UUID] = []
    var isEnabled = true

    init(_ combo: KeyCombo?, _ actionID: String, arguments: [String: ActionValue] = [:]) {
        self.combo = combo
        self.actions = [ActionInvocation(actionID, arguments: arguments)]
    }
}

nonisolated enum LauncherPosition: String, Codable, Hashable, Sendable, CaseIterable {
    case upperThird, center
    var titleKey: String { "launcher.position.\(rawValue)" }
}

nonisolated struct LauncherSettings: Codable, Hashable, Sendable {
    var searchesFiles = true
    var searchesWindows = true
    var showsCalculator = true
    var webSearchTemplate = "https://duckduckgo.com/?q=%@"
    var position: LauncherPosition = .upperThird
    var clearsQueryOnOpen = true
    var showsRecent = true
}

nonisolated struct SwitcherSettings: Codable, Hashable, Sendable {
    var showsThumbnails = true
    var includesMinimized = true
    var includesHiddenApps = true
    var includesOtherSpaces = true
    var groupsByApp = false
    var thumbnailWidth: Double = 240
    /// Intercept ⌘⇥ itself (requires Accessibility). Off: Keystivo uses its own shortcut.
    var replacesCommandTab = true
}

nonisolated struct WindowSettings: Codable, Hashable, Sendable {
    var gap: Double = 0
    var cyclesOnRepeat = true
    var preservesSnapAcrossDisplays = true
    var layouts: [WindowLayout] = []
    var rules: [AppWindowRule] = []
    var dragSnap = DragSnapSettings()
    var focusFollowsMouse = FocusFollowsMouseSettings()
}

/// The window under the pointer becomes active once the pointer rests on it.
nonisolated struct FocusFollowsMouseSettings: Codable, Hashable, Sendable {
    var isEnabled = false
    /// Seconds the pointer must rest on a window.
    var delay: Double = 0.2
    var excludedApps: [String] = []
}

/// Drag a window to an edge or corner to snap it (Magnet-style).
nonisolated struct DragSnapSettings: Codable, Hashable, Sendable {
    var isEnabled = true
    var topEdgeMaximizes = true
    var bottomEdgeThirds = true
    /// Holding ⌘ while dragging disables snapping for that drag.
    var commandBypasses = true
    var excludedApps: [String] = []
}

/// Mouse, scrolling and keyboard remapping (Mos / SteerMouse / Karabiner-style).
nonisolated struct InputSettings: Codable, Hashable, Sendable {
    var scroll = ScrollSettings()
    var mouseButtons: [MouseButtonBinding] = [
        MouseButtonBinding(button: .button4, actions: [ActionInvocation("system.pressKeys", arguments: ["keys": .keyCombo(KeyCombo(33, .command))])]),
        MouseButtonBinding(button: .button5, actions: [ActionInvocation("system.pressKeys", arguments: ["keys": .keyCombo(KeyCombo(30, .command))])]),
    ]
    var hyper = HyperKeySettings()
    var remaps: [KeyRemap] = []
}

nonisolated enum MonitorMetric: String, Codable, Hashable, Sendable, CaseIterable {
    case cpu, memory, network, disk
    var titleKey: String { "monitor.metric.\(rawValue)" }
}

/// Menu bar icon manager (Bartender-style) and system monitor (iStat-style).
nonisolated struct MenuBarSettings: Codable, Hashable, Sendable {
    var managerEnabled = false
    /// Seconds before hidden icons collapse again (0 = never).
    var autoCollapseSeconds = 10
    var showsMonitor = false
    var monitorMetrics: [MonitorMetric] = [.cpu, .memory, .network]
}

nonisolated struct ToolsSettings: Codable, Hashable, Sendable {
    var colorFormat: ColorFormat = .hex
    var ocrShowsResult = true
    var pinsAfterCapture = false
    /// Open the annotation editor after "Capture area" (CleanShot-style).
    var annotatesAfterCapture = false
    // Screen recording
    var recordingFolder = "~/Movies/Keystivo"
    var recordingShowsCursor = true
    var recordingCapturesAudio = false
    var recordingCapturesMicrophone = false
    var recordingUsesHEVC = true
    var recordingCountdown = true
    var recordingAfter: RecordingFinishAction = .reveal
    // Displays
    /// Brightness keys adjust external monitors (DDC or software dimming).
    var brightnessKeysControlExternal = true
}

nonisolated enum RecordingFinishAction: String, Codable, Hashable, Sendable, CaseIterable {
    case reveal, open, copy
    var titleKey: String { "record.after.\(rawValue)" }
}

nonisolated struct FilesSettings: Codable, Hashable, Sendable {
    var rulesEnabled = false
    var folderRules: [FolderRule] = []
    /// Show the shelf when files are dragged (Yoink-style).
    var shelfOnDrag = false
}

/// Presentation helpers (KeyCastr / Presentify-style).
nonisolated struct PresentationSettings: Codable, Hashable, Sendable {
    var showsKeystrokes = false
    /// Only show chords with ⌘/⌥/⌃ (hides normal typing, e.g. passwords).
    var onlyShortcuts = true
    var showsClicks = false
    var highlightsCursor = false
}

nonisolated enum ScreenEdge: String, Codable, Hashable, Sendable, CaseIterable {
    case left, bottom, right, top
    var titleKey: String { "edge.\(rawValue)" }
}

nonisolated struct LauncherBarSettings: Codable, Hashable, Sendable {
    var isEnabled = false
    var edge: ScreenEdge = .left
    var pinnedApps: [String] = ["com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.Terminal", "com.apple.Notes"]
    var showsRunningApps = true
    var autoHides = true
    var iconSize: Double = 40
}

nonisolated struct DockSettings: Codable, Hashable, Sendable {
    var previewsEnabled = true
    var previewWidth: Double = 220
    /// Seconds the pointer rests on an icon before its preview appears.
    var previewDelay: Double = 0.35
    var launcherBar = LauncherBarSettings()
}

nonisolated enum HintStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case accent, yellow, dark
    var titleKey: String { "hintStyle.\(rawValue)" }
}

nonisolated struct NavigationSettings: Codable, Hashable, Sendable {
    var alphabet = HintLabelGenerator.defaultAlphabet
    var includesMenuBar = true
    var includesDock = false
    var hintSize: Double = 12
    var hintStyle: HintStyle = .accent
    var scrollStep: Double = 60
}

nonisolated struct AudioSettings: Codable, Hashable, Sendable {
    var appVolumeEnabled = true
    var appSettings: [String: AppAudioSetting] = [:]
    var profiles: [AudioProfile] = []
    var volumeStep: Double = 1.0 / 16.0
}

nonisolated struct GestureSettings: Codable, Hashable, Sendable {
    var trackpadEnabled = false
    var mouseEnabled = false
    var mouseButton: MouseGestureButton = .right
    var showsTrail = true
    var mouseExcludedApps: [String] = []
    var bindings: [GestureBinding] = GestureSettings.defaultBindings

    static var defaultBindings: [GestureBinding] {
        [
            GestureBinding(trigger: .trackpad(TrackpadGesture(kind: .tap, fingers: 4)), actions: [ActionInvocation("launcher.show")]),
            GestureBinding(trigger: .trackpad(TrackpadGesture(kind: .swipe, fingers: 3, direction: .left, modifiers: .option)), actions: [ActionInvocation("windows.snap.leftHalf")]),
            GestureBinding(trigger: .trackpad(TrackpadGesture(kind: .swipe, fingers: 3, direction: .right, modifiers: .option)), actions: [ActionInvocation("windows.snap.rightHalf")]),
            GestureBinding(trigger: .trackpad(TrackpadGesture(kind: .swipe, fingers: 3, direction: .up, modifiers: .option)), actions: [ActionInvocation("windows.snap.maximize")]),
            GestureBinding(trigger: .mouse(MouseGesture(strokes: "L")), actions: [ActionInvocation("system.pressKeys", arguments: ["keys": .keyCombo(KeyCombo(33, .command))])]),
            GestureBinding(trigger: .mouse(MouseGesture(strokes: "R")), actions: [ActionInvocation("system.pressKeys", arguments: ["keys": .keyCombo(KeyCombo(30, .command))])]),
            GestureBinding(trigger: .mouse(MouseGesture(strokes: "DR")), actions: [ActionInvocation("windows.close")]),
            GestureBinding(trigger: .mouse(MouseGesture(strokes: "UD")), actions: [ActionInvocation("windows.switcher")]),
        ]
    }
}

nonisolated struct AutomationSettings: Codable, Hashable, Sendable {
    var isEnabled = true
    var workflows: [Workflow] = []
}

nonisolated struct SnippetSettings: Codable, Hashable, Sendable {
    var expansionEnabled = true
    var snippets: [Snippet] = [
        Snippet(name: "Today", keyword: ";date", content: "{date}", collection: "Dates"),
        Snippet(name: "ISO date", keyword: ";iso", content: "{date:yyyy-MM-dd}", collection: "Dates"),
        Snippet(name: "Shrug", keyword: ";shrug", content: "¯\\_(ツ)_/¯", collection: "Fun"),
    ]
    var excludedApps: [String] = []
}

/// "İş ve kişisel kullanım profilleri" / "Kullanıcı profilleri".
nonisolated struct UserProfile: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var symbolName: String
    var colorName = "blue"
    var audioProfileID: UUID?
    var powerProfileID: String?
    var layoutID: UUID?
    var inputSourceID: String?
    var startsFocus = false
    var launchApps: [String] = []
    var quitApps: [String] = []
    var hideApps: [String] = []
    var activationActions: [ActionInvocation] = []

    init(name: String, symbolName: String, colorName: String = "blue") {
        self.name = name
        self.symbolName = symbolName
        self.colorName = colorName
    }
}

/// "Uygulama grupları".
nonisolated struct AppGroup: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var symbolName = "square.stack.3d.up"
    var bundleIDs: [String]
}

nonisolated struct WorkspaceSettings: Codable, Hashable, Sendable {
    var profiles: [UserProfile] = []
    var activeProfileID: UUID?
    var appGroups: [AppGroup] = []
    var focus = FocusSettings()
}

nonisolated struct SystemSettings: Codable, Hashable, Sendable {
    var powerProfiles: [PowerProfile] = PowerProfile.builtIn
    var activePowerProfileID: String?
    var autoSwitchesPowerProfiles = false
    var inputSourceRules: [String: String] = [:]
    var remembersInputSourcePerApp = false
    var deviceProfiles: [InputDeviceProfile] = []
    var chargeLimit = ChargeLimitSettings()
}

nonisolated struct PluginSettings: Codable, Hashable, Sendable {
    var trusted: [String: String] = [:]
    var disabled: [String] = []
}

/// Everything Keystivo persists (except clipboard history), in one JSON document.
nonisolated struct KeystivoConfiguration: Codable, Hashable, Sendable {
    static let currentSchema = 1

    var schemaVersion = KeystivoConfiguration.currentSchema
    var general = GeneralSettings()
    var hotkeys: [HotkeyBinding] = []
    var launcher = LauncherSettings()
    var switcher = SwitcherSettings()
    var windows = WindowSettings()
    var dock = DockSettings()
    var navigation = NavigationSettings()
    var audio = AudioSettings()
    var gestures = GestureSettings()
    var automation = AutomationSettings()
    var clipboard = ClipboardSettings()
    var snippets = SnippetSettings()
    var workspace = WorkspaceSettings()
    var system = SystemSettings()
    var plugins = PluginSettings()
    var input = InputSettings()
    var menuBar = MenuBarSettings()
    var tools = ToolsSettings()
    var files = FilesSettings()
    var links = LinkSettings()
    var presentation = PresentationSettings()
    var usage: [String: UsageStats] = [:]

    /// Sections that can be exported/imported independently.
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case general, hotkeys, launcher, switcher, windows, dock, navigation, audio, gestures, automation, clipboard, snippets, workspace, system, plugins
        case input, menuBar, tools, files, links, presentation
        var id: String { rawValue }
        var titleKey: String { "settings.section.\(rawValue)" }
    }
}
