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
@preconcurrency import Translation

/// State and search logic of the launcher. Providers live in LauncherProviders.swift.
@Observable
final class LauncherModel {
    @ObservationIgnored unowned let runtime: KeystivoRuntime

    private(set) var mode: LauncherMode = .root
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var sections: [LauncherSectionGroup] = []
    private(set) var items: [LauncherItem] = []
    var selectedIndex = 0 {
        didSet { if selectedIndex != oldValue { pendingConfirmationID = nil } }
    }
    var isActionPanelOpen = false
    var actionIndex = 0
    private(set) var pendingConfirmationID: String?
    private(set) var isLoading = false
    private(set) var pluginText: String?
    /// Source text for the text-actions mode (selected text or clipboard).
    private(set) var textInput = ""
    private(set) var focusToken = 0
    /// Short message shown in the footer (e.g. "Copied").
    private(set) var toast: String?
    /// Drives the SwiftUI translation task (on-device Apple Translation).
    var translationConfiguration: TranslationSession.Configuration?
    @ObservationIgnored var translationText = ""

    @ObservationIgnored var onDismiss: (() -> Void)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var asyncItems: [LauncherItem] = []
    @ObservationIgnored var windowCache: [WindowInfo] = []
    @ObservationIgnored private var pluginItems: [LauncherItem] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
    }

    var selectedItem: LauncherItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    // MARK: Opening

    func open(mode: LauncherMode) {
        if runtime.config.launcher.clearsQueryOnOpen || mode != self.mode { query = "" }
        self.mode = mode
        isActionPanelOpen = false
        pendingConfirmationID = nil
        pluginText = nil
        focusToken += 1
        if mode == .root || mode == .windows {
            Task {
                var options = WindowCatalog.Options()
                options.includeOtherSpaces = runtime.config.switcher.includesOtherSpaces
                windowCache = await WindowCatalog.shared.windows(options: options)
                refresh()
            }
        }
        if mode == .textActions { textInput = Self.selectedTextOrClipboard() }
        AppCatalog.shared.refreshIfNeeded()
        PluginManager.shared.reload()
        refresh()
    }

    func showPluginOutput(_ output: PluginOutput, title: String) {
        query = ""
        mode = .pluginOutput(title: title)
        isActionPanelOpen = false
        switch output {
        case .text(let text):
            pluginText = text
            pluginItems = []
        case .items(let list):
            pluginText = nil
            pluginItems = list.enumerated().map { index, item in pluginLauncherItem(item, index: index) }
        case .done:
            pluginText = nil
            pluginItems = []
        }
        focusToken += 1
        refresh()
    }

    private func queryChanged() {
        selectedIndex = 0
        refresh()
    }

    // MARK: Searching

    func refresh() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        var results = synchronousItems(for: text)
        apply(results)

        let needsAsync: Bool = switch mode {
        case .root: text.count >= 3 && runtime.config.launcher.searchesFiles
        case .clipboard, .files: true
        default: false
        }
        guard needsAsync else { asyncItems = []; return }
        isLoading = true
        searchTask = Task {
            // Debounce typing bursts before hitting Spotlight/SQLite.
            try? await Task.sleep(for: .milliseconds(mode == .clipboard ? 40 : 180))
            guard !Task.isCancelled else { return }
            let extra = await asynchronousItems(for: text)
            guard !Task.isCancelled else { return }
            asyncItems = extra
            results.append(contentsOf: extra)
            apply(results)
            isLoading = false
        }
    }

    private func apply(_ results: [LauncherItem]) {
        let previousID = selectedItem?.id
        var grouped: [LauncherSection: [LauncherItem]] = [:]
        for item in results { grouped[item.section, default: []].append(item) }
        var groups: [LauncherSectionGroup] = []
        let ordered: [LauncherSection]
        if mode == .root, !query.isEmpty {
            // Calculator first, fallbacks last, everything else by best score.
            ordered = grouped.keys.sorted { lhs, rhs in
                if lhs == .calculator { return true }
                if rhs == .calculator { return false }
                if lhs == .fallback { return false }
                if rhs == .fallback { return true }
                let left = grouped[lhs]?.map(\.score).max() ?? 0
                let right = grouped[rhs]?.map(\.score).max() ?? 0
                return left > right
            }
        } else {
            ordered = grouped.keys.sorted()
        }
        for section in ordered {
            var list = grouped[section] ?? []
            if section != .results && section != .clipboard && section != .snippets {
                list.sort { $0.score > $1.score }
            }
            if mode == .root { list = Array(list.prefix(section.limit)) }
            if !list.isEmpty { groups.append(LauncherSectionGroup(section: section, items: list)) }
        }
        sections = groups
        items = groups.flatMap(\.items)
        if let previousID, let index = items.firstIndex(where: { $0.id == previousID }), !query.isEmpty {
            selectedIndex = index
        } else if selectedIndex >= items.count {
            selectedIndex = max(items.count - 1, 0)
        }
    }

    // MARK: Navigation

    func moveSelection(_ delta: Int) {
        if isActionPanelOpen {
            let count = selectedItem?.allActions.count ?? 0
            guard count > 0 else { return }
            actionIndex = (actionIndex + delta + count) % count
            return
        }
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
    }

    func toggleActionPanel() {
        guard selectedItem != nil else { return }
        isActionPanelOpen.toggle()
        actionIndex = 0
    }

    /// Escape: close the action panel, then leave a sub-mode, then dismiss.
    func back() {
        if isActionPanelOpen {
            isActionPanelOpen = false
        } else if !query.isEmpty && mode == .root {
            query = ""
        } else if mode != .root {
            open(mode: .root)
        } else {
            onDismiss?()
        }
    }

    func performSelected(alternate: Bool = false) {
        guard let item = selectedItem else { return }
        if isActionPanelOpen {
            let actions = item.allActions
            guard actions.indices.contains(actionIndex) else { return }
            perform(actions[actionIndex], of: item)
            return
        }
        if alternate, let first = item.actions.first {
            perform(first, of: item)
            return
        }
        if item.requiresConfirmation, pendingConfirmationID != item.id {
            pendingConfirmationID = item.id
            return
        }
        perform(item.primary, of: item)
    }

    func perform(_ action: LauncherAction, of item: LauncherItem) {
        if let key = item.usageKey { runtime.recordUsage(key) }
        isActionPanelOpen = false
        pendingConfirmationID = nil
        if action.dismisses { onDismiss?() }
        Task { await action.perform() }
    }

    /// Runs an item action identified by its keyboard shortcut (e.g. ⌘C).
    func performShortcut(_ combo: KeyCombo) -> Bool {
        guard let item = selectedItem, let action = item.allActions.first(where: { $0.shortcut == combo }) else { return false }
        perform(action, of: item)
        return true
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    // MARK: Helpers

    /// Selected text from the focused element of the frontmost app, else the clipboard.
    static func selectedTextOrClipboard() -> String {
        if AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication {
            let element = AXElement.application(pid: app.processIdentifier).focusedElement
            if let text: String = element?.attribute(kAXSelectedTextAttribute), !text.isEmpty { return text }
        }
        return NSPasteboard.general.string(forType: .string) ?? ""
    }

    var pluginResultItems: [LauncherItem] { pluginItems }

    /// Starts an on-device translation of `text` into `target`.
    func translate(_ text: String, to target: Locale.Language) {
        translationText = text
        isLoading = true
        if translationConfiguration?.target == target {
            translationConfiguration?.invalidate()
        } else {
            translationConfiguration = TranslationSession.Configuration(source: nil, target: target)
        }
    }

    func translationFinished(_ result: Result<String, any Error>) {
        isLoading = false
        switch result {
        case .success(let text):
            Pasteboard.copy(text)
            showPluginOutput(.text(text), title: L("text.translation"))
        case .failure(let error):
            showToast(error.localizedDescription)
        }
    }
}

struct LauncherSectionGroup: Identifiable {
    var id: Int { section.rawValue }
    let section: LauncherSection
    let items: [LauncherItem]
}
