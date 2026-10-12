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
import KeystivoScreenSaver
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
    /// Keyword web searches and links ("yt cats").
    var quicklinks: [Quicklink] = Quicklink.defaults
    /// "100 usd to try": downloads ECB reference rates when such a query is typed.
    var convertsCurrency = true
    /// User aliases: item key (bundle ID, "action:…", "workflow:…", "quicklink:…") → alias.
    var aliases: [String: String] = [:]
}

/// A keyword search or link, like Raycast quicklinks or Alfred web searches.
/// `{query}` is replaced with the typed text (URL-encoded), `{clipboard}` with the clipboard.
nonisolated struct Quicklink: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var keyword: String
    var url: String
    /// Open with this app instead of the default handler.
    var appBundleID: String?

    var takesQuery: Bool { url.contains("{query}") }

    /// The URL for `query`, or nil when the template doesn't form a valid URL.
    func resolvedURL(query: String, clipboard: String? = nil) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        var resolved = url.replacingOccurrences(of: "{query}", with: encode(query))
        if resolved.contains("{clipboard}") { resolved = resolved.replacingOccurrences(of: "{clipboard}", with: encode(clipboard ?? "")) }
        if resolved.hasPrefix("~") || resolved.hasPrefix("/") {
            return URL(fileURLWithPath: (resolved as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: resolved), url.scheme != nil else { return nil }
        return url
    }

    static let defaults: [Quicklink] = [
        Quicklink(name: "Google", keyword: "g", url: "https://www.google.com/search?q={query}"),
        Quicklink(name: "YouTube", keyword: "yt", url: "https://www.youtube.com/results?search_query={query}"),
        Quicklink(name: "Wikipedia", keyword: "wiki", url: "https://wikipedia.org/w/index.php?search={query}"),
        Quicklink(name: "GitHub", keyword: "gh", url: "https://github.com/search?q={query}"),
        Quicklink(name: "Google Maps", keyword: "map", url: "https://www.google.com/maps/search/{query}"),
        Quicklink(name: "Google Translate", keyword: "tr", url: "https://translate.google.com/?sl=auto&text={query}"),
        Quicklink(name: "Stack Overflow", keyword: "so", url: "https://stackoverflow.com/search?q={query}"),
        Quicklink(name: "App Store", keyword: "as", url: "macappstore://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?q={query}"),
    ]
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
    /// Running apps without windows appear too (selecting one reopens it).
    var includesWindowlessApps = true
    /// Apps never shown in the switcher.
    var excludedApps: [String] = []
    /// While one of these apps is frontmost, ⌘⇥ stays the system's (games, VMs, remote desktops).
    var systemSwitcherApps: [String] = []
}

nonisolated struct WindowSettings: Codable, Hashable, Sendable {
    var gap: Double = 0
    var cyclesOnRepeat = true
    var preservesSnapAcrossDisplays = true
    var layouts: [WindowLayout] = []
    var rules: [AppWindowRule] = []
    var dragSnap = DragSnapSettings()
    var focusFollowsMouse = FocusFollowsMouseSettings()
    var modifierDrag = ModifierDragSettings()
    var windowButtons = WindowButtonSettings()
    /// Repeating ← / → half at the screen edge continues onto the next display.
    var repeatMovesAcrossDisplays = false
    /// A snapped window gets its earlier size back when dragged away.
    var restoresSizeOnDrag = true
}

/// Custom actions for the red, yellow and green title bar buttons.
nonisolated struct WindowButtonSettings: Codable, Hashable, Sendable {
    var isEnabled = false
    /// "close.click", "zoom.rightClick"… → action; missing means macOS's own.
    var actions: [String: WindowButtonAction] = [:]
    var excludedApps: [String] = []

    /// Red quits the app, yellow fills the screen, green minimizes.
    static let quickPreset: [String: WindowButtonAction] = [
        "close.click": .quitApp, "minimize.click": .maximize, "zoom.click": .minimize,
    ]
}

/// Hold modifiers and drag anywhere in a window to move it, right-drag to resize.
nonisolated struct ModifierDragSettings: Codable, Hashable, Sendable {
    var isEnabled = true
    var modifiers: ModifierChoice = .controlOption
    var raisesWindow = true
    var excludedApps: [String] = []
}

nonisolated enum ModifierChoice: String, Codable, Hashable, Sendable, CaseIterable {
    case controlOption, commandControl, commandOption, controlOptionCommand

    var modifiers: KeyModifiers {
        switch self {
        case .controlOption: [.control, .option]
        case .commandControl: [.command, .control]
        case .commandOption: [.command, .option]
        case .controlOptionCommand: [.control, .option, .command]
        }
    }

    var symbols: String { modifiers.symbols }
}

/// The window under the pointer becomes active once the pointer rests on it.
nonisolated struct FocusFollowsMouseSettings: Codable, Hashable, Sendable {
    var isEnabled = false
    /// Seconds the pointer must rest on a window.
    var delay: Double = 0.2
    /// Seconds to wait after the pointer moved to another display.
    var displayChangeDelay: Double = 0.2
    /// Moving to another display activates its front window, even over the desktop.
    var focusesDisplayOnEnter = false
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
    case cpu, memory, network, disk, gpu, sensors

    /// Needs GPU, temperature or fan readings.
    var usesHardware: Bool { self == .gpu || self == .sensors }
    var titleKey: String { "monitor.metric.\(rawValue)" }
}

/// Menu bar icon manager (Bartender-style) and system monitor (iStat-style).
nonisolated struct MenuBarSettings: Codable, Hashable, Sendable {
    var managerEnabled = false
    /// Seconds before hidden icons collapse again (0 = never).
    var autoCollapseSeconds = 10
    var showsMonitor = false
    var monitorMetrics: [MonitorMetric] = [.cpu, .memory, .network]
    /// Per-metric look (Stats-style widgets), keyed by metric.
    var monitorWidgets: [String: MonitorWidgetSettings] = [:]
    /// What the disk metric shows.
    var diskValue: DiskValueMode = .freeSpace
    /// What the Keystivo menu bar panel shows, and how.
    var controlCenter = ControlCenterSettings()
    /// A separate menu bar item with the sound mixer (per-app volume).
    var showsMixerItem = false

    func widget(for metric: MonitorMetric) -> MonitorWidgetSettings {
        monitorWidgets[metric.rawValue] ?? .default(for: metric)
    }
}

/// The Keystivo menu bar panel: which modules it shows, in which order, and its look.
nonisolated struct ControlCenterSettings: Codable, Hashable, Sendable {
    /// Shown modules, top to bottom; missing ones are hidden.
    var modules: [ControlCenterModule] = ControlCenterModule.defaultOrder
    var toggles: [ControlCenterToggle] = ControlCenterToggle.defaults
    /// Action IDs of the quick actions list.
    var actions: [String] = ControlCenterSettings.defaultActions
    var background: PanelBackground = .glass

    static let defaultActions = [
        "tools.captureText", "tools.recordScreen", "tools.pickColor",
        "system.lockScreen", "system.sleepDisplays", "system.emptyTrash",
    ]
}

nonisolated enum ControlCenterModule: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case toggles, widgets, sound, displays, windows, actions, power
    var id: String { rawValue }
    var titleKey: String { "cc.module.\(rawValue)" }
    var symbol: String {
        switch self {
        case .toggles: "switch.2"
        case .widgets: "square.grid.2x2"
        case .sound: "speaker.wave.2"
        case .displays: "sun.max"
        case .windows: "rectangle.split.2x1"
        case .actions: "bolt"
        case .power: "battery.75percent"
        }
    }
    static let defaultOrder: [ControlCenterModule] = [.toggles, .sound, .displays, .windows, .actions, .power]
}

nonisolated enum ControlCenterToggle: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case focus, keepAwake, mic, darkMode, clipboard, snippets, gestures, automation, launcherBar, focusFollowsMouse, dragSnap
    var id: String { rawValue }
    var titleKey: String { "cc.toggle.\(rawValue)" }
    static let defaults: [ControlCenterToggle] = [.focus, .keepAwake, .mic, .darkMode, .clipboard, .snippets, .gestures, .automation]
}

/// Background of Keystivo's floating panels.
nonisolated enum PanelBackground: String, Codable, Hashable, Sendable, CaseIterable {
    /// Frosted glass: the desktop shows through, blurred.
    case glass
    /// More see-through glass.
    case clear
    /// Opaque, for the most contrast.
    case solid
    var titleKey: String { "panelBackground.\(rawValue)" }
}

/// How one menu bar metric is drawn.
nonisolated struct MonitorWidgetSettings: Codable, Hashable, Sendable {
    var style: MonitorWidgetStyle
    var color: MonitorColorMode = .monochrome
    /// Small caption ("CPU", "RAM"…) on mini, chart and gauge styles.
    var showsLabel = true
    /// Symbol before the value on the compact style.
    var showsIcon = true

    static func `default`(for metric: MonitorMetric) -> MonitorWidgetSettings {
        MonitorWidgetSettings(style: metric == .network ? .twoLine : .compact)
    }
}

nonisolated enum MonitorWidgetStyle: String, Codable, Hashable, Sendable, CaseIterable {
    /// Symbol and value.
    case compact
    /// Tiny caption above the value.
    case mini
    case lineChart
    /// Per-core bars for CPU, one level bar otherwise.
    case barChart
    case pie
    /// Needle gauge.
    case gauge
    /// Two values stacked: used/total, upload/download, temperature/fan.
    case twoLine
    /// The value alone.
    case text

    var titleKey: String { "monitor.style.\(rawValue)" }

    static func available(for metric: MonitorMetric) -> [MonitorWidgetStyle] {
        switch metric {
        case .cpu, .gpu: [.compact, .mini, .lineChart, .barChart, .pie, .gauge, .text]
        case .memory: [.compact, .mini, .lineChart, .barChart, .pie, .gauge, .twoLine, .text]
        // Disk use changes too slowly for a line chart.
        case .disk: [.compact, .mini, .barChart, .pie, .gauge, .twoLine, .text]
        case .network: [.twoLine, .lineChart, .compact, .text]
        case .sensors: [.compact, .mini, .lineChart, .gauge, .twoLine, .text]
        }
    }
}

nonisolated enum MonitorColorMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Follows the menu bar's text color.
    case monochrome
    /// Green, then orange, then red as the value rises.
    case utilization
    case accent
    case blue, green, orange, red, purple, pink, teal

    var titleKey: String { "monitor.color.\(rawValue)" }
}

nonisolated enum DiskValueMode: String, Codable, Hashable, Sendable, CaseIterable {
    case freeSpace, usedPercent, freePercent, usedSpace
    var titleKey: String { "monitor.disk.\(rawValue)" }
}

/// Keystivo's own screen saver: started by Keystivo after a while idle, so it
/// can float over the desktop (see-through, dimmed or frosted).
nonisolated struct KeystivoSaverSettings: Codable, Hashable, Sendable {
    var startsWhenIdle = false
    var idleMinutes = 5
    var style: SaverStyle = .glass
    var backdrop: SaverBackdrop = .frosted
}

nonisolated struct ToolsSettings: Codable, Hashable, Sendable {
    var keystivoSaver = KeystivoSaverSettings()
    var colorFormat: ColorFormat = .hex
    var ocrShowsResult = true
    var pinsAfterCapture = false
    /// Open the annotation editor after "Capture area" (CleanShot-style).
    var annotatesAfterCapture = false
    /// Also save screenshots as PNG files here (empty: clipboard only).
    var screenshotFolder = ""
    /// Window screenshots keep the window shadow.
    var screenshotShadow = true
    /// After a screenshot, show a thumbnail to drag, copy, save, annotate or pin (CleanShot-style).
    var showsQuickAccess = true
    // Screen recording
    var recordingFolder = "~/Movies/Keystivo"
    var recordingShowsCursor = true
    var recordingCapturesAudio = false
    var recordingCapturesMicrophone = false
    var recordingUsesHEVC = true
    var recordingCountdown = true
    var recordingAfter: RecordingFinishAction = .reveal
    var recordingFormat: RecordingFormat = .mov
    var recordingFrameRate = 60
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
    var widgets = WidgetSettings()
    var usage: [String: UsageStats] = [:]

    /// Sections that can be exported/imported independently.
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case general, hotkeys, launcher, switcher, windows, dock, navigation, audio, gestures, automation, clipboard, snippets, workspace, system, plugins
        case input, menuBar, tools, files, links, presentation, widgets
        var id: String { rawValue }
        var titleKey: String { "settings.section.\(rawValue)" }
    }
}
