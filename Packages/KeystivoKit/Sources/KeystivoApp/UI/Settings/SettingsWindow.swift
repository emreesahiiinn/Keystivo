import AppKit
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
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, profiles, shortcuts
    case launcher, clipboard, snippets, automation, plugins
    case switcher, windows, dock, workspaces
    case navigation, gestures, mouseKeyboard, audio, system
    case widgets, menuBar, screenTools, displays, screenSavers, battery, files, links, presentation
    case diagnostics, backup, about

    var id: String { rawValue }
    var titleKey: String { "settings.page.\(rawValue)" }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .profiles: "person.2.fill"
        case .shortcuts: "command"
        case .launcher: "magnifyingglass"
        case .clipboard: "clipboard.fill"
        case .snippets: "text.badge.plus"
        case .automation: "bolt.fill"
        case .plugins: "puzzlepiece.extension.fill"
        case .switcher: "rectangle.on.rectangle"
        case .windows: "macwindow.on.rectangle"
        case .dock: "dock.rectangle"
        case .workspaces: "rectangle.3.group.fill"
        case .navigation: "keyboard.fill"
        case .gestures: "hand.draw.fill"
        case .audio: "speaker.wave.2.fill"
        case .system: "cpu.fill"
        case .mouseKeyboard: "computermouse.fill"
        case .widgets: "square.grid.2x2.fill"
        case .menuBar: "menubar.rectangle"
        case .screenTools: "viewfinder"
        case .displays: "sun.max.fill"
        case .screenSavers: "sparkles.tv"
        case .battery: "battery.100percent.bolt"
        case .files: "folder.fill.badge.gearshape"
        case .links: "link.circle.fill"
        case .presentation: "play.rectangle.fill"
        case .diagnostics: "stethoscope"
        case .backup: "arrow.up.arrow.down.square.fill"
        case .about: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general, .system: .gray
        case .profiles: .purple
        case .shortcuts: .indigo
        case .launcher: .blue
        case .clipboard: .orange
        case .snippets: .teal
        case .automation: .yellow
        case .plugins: .cyan
        case .switcher, .windows: .blue
        case .dock: .indigo
        case .workspaces: .purple
        case .navigation: .teal
        case .gestures: .mint
        case .audio: .pink
        case .diagnostics: .red
        case .mouseKeyboard: .mint
        case .widgets: .orange
        case .menuBar: .indigo
        case .screenTools: .orange
        case .displays: .yellow
        case .screenSavers: .purple
        case .battery: .green
        case .files: .blue
        case .links: .teal
        case .presentation: .red
        case .backup: .green
        case .about: .gray
        }
    }

    static let groups: [(String, [SettingsSection])] = [
        ("settings.group.keystivo", [.general, .profiles, .shortcuts]),
        ("settings.group.productivity", [.launcher, .clipboard, .snippets, .automation, .plugins]),
        ("settings.group.windows", [.switcher, .windows, .dock, .workspaces]),
        ("settings.group.input", [.navigation, .gestures, .mouseKeyboard, .audio, .system]),
        ("settings.group.utilities", [.widgets, .menuBar, .screenTools, .displays, .screenSavers, .battery, .files, .links, .presentation]),
        ("settings.group.support", [.diagnostics, .backup, .about]),
    ]
}

@Observable
final class SettingsNavigation {
    var selection: SettingsSection = .general
    /// When set, the shortcuts page opens an editor for a new binding of this action.
    var pendingBindingActionID: String?
}

/// Owns Keystivo's standard windows (Settings, Welcome) and switches the
/// activation policy so they appear in the Dock and ⌘⇥ while open.
final class WindowPresenter: NSObject, NSWindowDelegate {
    private unowned let runtime: KeystivoRuntime
    let navigation = SettingsNavigation()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var uninstallerWindow: NSWindow?

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    var hasVisibleStandardWindow: Bool {
        settingsWindow?.isVisible == true || onboardingWindow?.isVisible == true || uninstallerWindow?.isVisible == true
    }

    func showUninstaller() {
        let window = uninstallerWindow ?? makeWindow(
            title: L("uninstall.title"), size: CGSize(width: 860, height: 560),
            content: UninstallerView(), autosave: "KeystivoUninstaller", resizable: true
        )
        uninstallerWindow = window
        if window.frame.origin == .zero { window.center() }
        present(window)
    }

    func showSettings(section: SettingsSection = .general, newBindingFor actionID: String? = nil) {
        navigation.selection = section
        navigation.pendingBindingActionID = actionID
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        present(window)
    }

    /// ⌘, from any Keystivo panel: brings Settings back where the user left it.
    func showSettingsAtLastSection() {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        present(window)
    }

    var isSettingsKey: Bool { settingsWindow?.isKeyWindow == true }

    func showOnboarding() {
        let window = onboardingWindow ?? makeWindow(
            title: L("onboarding.windowTitle"),
            size: CGSize(width: 720, height: 560),
            content: OnboardingView(runtime: runtime) { [weak self] in
                self?.onboardingWindow?.close()
            },
            autosave: nil,
            resizable: false
        )
        onboardingWindow = window
        window.center()
        present(window)
    }

    private func present(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        runtime.applyActivationPolicy()
        NSApp.activate()
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = makeWindow(
            title: L("settings.windowTitle"),
            size: CGSize(width: 1000, height: 700),
            content: SettingsRootView(runtime: runtime, navigation: navigation),
            autosave: "KeystivoSettingsWindow",
            resizable: true
        )
        window.toolbarStyle = .unified
        window.minSize = CGSize(width: 820, height: 560)
        if window.frame.origin == .zero { window.center() }
        return window
    }

    private func makeWindow<Content: View>(title: String, size: CGSize, content: Content, autosave: String?, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = !resizable
        window.contentViewController = NSHostingController(rootView: content.localizedRoot())
        window.setContentSize(size)
        window.delegate = self
        if let autosave { window.setFrameAutosaveName(autosave) }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.runtime.applyActivationPolicy() }
    }
}

struct SettingsRootView: View {
    let runtime: KeystivoRuntime
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(SettingsSection.groups, id: \.0) { group in
                    Section(L(group.0)) {
                        ForEach(group.1) { section in
                            NavigationLink(value: section) {
                                Label {
                                    HStack {
                                        Text(L(section.titleKey))
                                        Spacer()
                                        if section == .diagnostics, DiagnosticsCenter.shared.unseenErrorCount > 0 || PermissionCenter.shared.missingEssential {
                                            Circle().fill(.orange).frame(width: 7, height: 7)
                                        }
                                    }
                                } icon: {
                                    SymbolTile(symbol: section.symbol, color: section.color, size: 20)
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            page(for: navigation.selection)
                .navigationTitle(L(navigation.selection.titleKey))
        }
    }

    @ViewBuilder
    private func page(for section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralPage(runtime: runtime)
        case .profiles: ProfilesPage(runtime: runtime)
        case .shortcuts: ShortcutsPage(runtime: runtime, navigation: navigation)
        case .launcher: LauncherPage(runtime: runtime)
        case .clipboard: ClipboardPage(runtime: runtime)
        case .snippets: SnippetsPage(runtime: runtime)
        case .automation: AutomationPage(runtime: runtime)
        case .plugins: PluginsPage(runtime: runtime)
        case .switcher: SwitcherPage(runtime: runtime)
        case .windows: WindowsPage(runtime: runtime)
        case .dock: DockPage(runtime: runtime)
        case .workspaces: WorkspacesPage(runtime: runtime)
        case .navigation: NavigationPage(runtime: runtime)
        case .gestures: GesturesPage(runtime: runtime)
        case .audio: AudioPage(runtime: runtime)
        case .system: SystemPage(runtime: runtime)
        case .mouseKeyboard: MouseKeyboardPage(runtime: runtime)
        case .widgets: WidgetsPage(runtime: runtime)
        case .menuBar: MenuBarPage(runtime: runtime)
        case .screenTools: ScreenToolsPage(runtime: runtime)
        case .displays: DisplaysPage(runtime: runtime)
        case .screenSavers: ScreenSaversPage(runtime: runtime)
        case .battery: BatteryPage(runtime: runtime)
        case .files: FilesPage(runtime: runtime)
        case .links: LinksPage(runtime: runtime)
        case .presentation: PresentationPage(runtime: runtime)
        case .diagnostics: DiagnosticsPage(runtime: runtime)
        case .backup: BackupPage(runtime: runtime)
        case .about: AboutPage()
        }
    }
}

/// Shortcut field bound to the first binding of a single action (creating it on demand).
struct ActionShortcutField: View {
    @Bindable var runtime: KeystivoRuntime
    let actionID: String

    var body: some View {
        KeyRecorder(combo: Binding(
            get: { runtime.config.hotkeys.first { $0.actions.count == 1 && $0.actions[0].actionID == actionID && $0.appBundleIDs.isEmpty }?.combo },
            set: { combo in
                if let index = runtime.config.hotkeys.firstIndex(where: { $0.actions.count == 1 && $0.actions[0].actionID == actionID && $0.appBundleIDs.isEmpty }) {
                    if let combo { runtime.config.hotkeys[index].combo = combo } else { runtime.config.hotkeys.remove(at: index) }
                } else if let combo {
                    runtime.config.hotkeys.append(HotkeyBinding(combo, actionID))
                }
            }
        ))
    }
}
