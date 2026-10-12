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
    /// Result row frames and the list's visible frame, in window coordinates
    /// (top-left origin); a right-click selects the row under the pointer.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]
    @ObservationIgnored var listFrame: CGRect = .zero
    #if DEBUG
    /// Automated visual checks: sample clipboard rows, and actions do nothing
    /// (the panel takes keyboard focus, so a stray Return must not paste or delete).
    @ObservationIgnored var isInertForTesting = false
    #endif
    /// Clipboard mode: asking whether to clear the whole history.
    private(set) var isConfirmingClear = false
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
    /// Mode whose results are on screen (async-only lists keep them while reloading).
    @ObservationIgnored private var displayedMode: LauncherMode?
    // Extras (LauncherExtras.swift).
    @ObservationIgnored var exchangeRates: ExchangeRates.Table?
    @ObservationIgnored var isLoadingRates = false
    @ObservationIgnored var menuEntries: [MenuItemEntry] = []
    @ObservationIgnored var menuTargetPID: pid_t?
    var menuTargetName: String?
    var isLoadingMenus = false
    @ObservationIgnored var processRows: [ProcessUsage] = []
    @ObservationIgnored var processTask: Task<Void, Never>?
    /// Selection copied with ⌘C just before the panel opened (see LauncherController.show).
    @ObservationIgnored var prefetchedSelection: String?
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
        isConfirmingClear = false
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
        if mode == .textActions { textInput = prefetchedSelection ?? Self.selectedTextOrClipboard() }
        prefetchedSelection = nil
        if mode == .menuItems { loadMenuItems() }
        if mode == .schedule, !CalendarService.shared.hasAccess {
            Task {
                _ = await CalendarService.shared.requestAccess()
                refresh()
            }
        }
        if mode == .processes { startProcessSampling() } else { processTask?.cancel() }
        if mode == .root, runtime.config.launcher.convertsCurrency, exchangeRates == nil {
            Task { exchangeRates = await ExchangeRates.shared.cached() }
        }
        AppCatalog.shared.refreshIfNeeded()
        PluginManager.shared.reload()
        selectedIndex = 0
        reload(keepingSelection: false)
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
        reload(keepingSelection: false)
    }

    // MARK: Searching

    /// Re-runs the current search in place: the rows stay on screen until fresh
    /// results arrive and the selected item stays selected.
    func refresh() {
        reload(keepingSelection: true)
    }

    private func reload(keepingSelection: Bool) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        var results = synchronousItems(for: text)
        let needsAsync: Bool = switch mode {
        case .root: text.count >= 3 && runtime.config.launcher.searchesFiles
        case .clipboard, .files: true
        default: false
        }
        // Lists that only have async results (clipboard, files) keep their rows
        // until the new ones arrive, instead of flashing empty.
        let keepsRows = needsAsync && results.isEmpty && displayedMode == mode && !items.isEmpty
        if !keepsRows {
            apply(results, selecting: keepingSelection ? selectedItem?.id : nil)
        }
        guard needsAsync else {
            asyncItems = []
            isLoading = false
            return
        }
        searchTask = Task {
            // Debounce typing bursts before hitting Spotlight/SQLite.
            try? await Task.sleep(for: .milliseconds(mode == .clipboard ? 40 : 180))
            guard !Task.isCancelled else { return }
            // Only slow searches show the spinner.
            let spinner = Task {
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled { isLoading = true }
            }
            let extra = await asynchronousItems(for: text)
            spinner.cancel()
            guard !Task.isCancelled else { return }
            asyncItems = extra
            results.append(contentsOf: extra)
            // Rows already on screen for this query: keep what the user selected meanwhile.
            apply(results, selecting: keepingSelection || !keepsRows ? selectedItem?.id : nil)
            isLoading = false
        }
    }

    /// Shows `results`; `anchor` is the item to keep selected when still present.
    private func apply(_ results: [LauncherItem], selecting anchor: String?) {
        displayedMode = mode
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
            if section != .results && section != .clipboard {
                list.sort { $0.score > $1.score }
            }
            if mode == .root { list = Array(list.prefix(section.limit)) }
            if !list.isEmpty { groups.append(LauncherSectionGroup(section: section, items: list)) }
        }
        // The same item can come from several providers (e.g. an alias and a fuzzy match):
        // keep its best-scored copy, and give every aliasable item "Set Alias…".
        var seen = Set<String>()
        groups = groups.compactMap { group in
            let unique = group.items.filter { seen.insert($0.id).inserted }.map { item -> LauncherItem in
                guard let alias = aliasAction(for: item), !item.actions.contains(where: { $0.title == alias.title }) else { return item }
                var copy = item
                copy.actions.append(alias)
                return copy
            }
            return unique.isEmpty ? nil : LauncherSectionGroup(section: group.section, items: unique)
        }
        sections = groups
        items = groups.flatMap(\.items)
        if let anchor, let index = items.firstIndex(where: { $0.id == anchor }) {
            selectedIndex = index
        } else if selectedIndex >= items.count {
            selectedIndex = max(items.count - 1, 0)
        }
    }

    /// Removes rows right away, without waiting for a reload. The selection
    /// stays on the same slot, so it moves to the next row (like Mail).
    func removeItems(where shouldRemove: (LauncherItem) -> Bool) {
        let selectedID = selectedItem?.id
        let removed = Set(items.filter(shouldRemove).map(\.id))
        guard !removed.isEmpty else { return }
        let removedAbove = items.prefix(selectedIndex).filter { removed.contains($0.id) }.count
        withAnimation(.snappy(duration: 0.24)) {
            sections = sections.compactMap { group in
                let remaining = group.items.filter { !removed.contains($0.id) }
                return remaining.isEmpty ? nil : LauncherSectionGroup(section: group.section, items: remaining)
            }
            items = sections.flatMap(\.items)
            if let selectedID, !removed.contains(selectedID), let index = items.firstIndex(where: { $0.id == selectedID }) {
                selectedIndex = index
            } else {
                selectedIndex = min(max(selectedIndex - removedAbove, 0), max(items.count - 1, 0))
            }
        }
        asyncItems.removeAll { removed.contains($0.id) }
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
        #if DEBUG
        if isInertForTesting { return }
        #endif
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

    /// The result row at `point` (window coordinates, top-left origin).
    func rowIndex(at point: CGPoint) -> Int? {
        guard listFrame.contains(point) else { return nil }
        return rowFrames.first { items.indices.contains($0.key) && $0.value.contains(point) }?.key
    }

    // MARK: Clipboard history

    /// Asks (inside the launcher) whether to clear the clipboard history.
    func requestClearClipboard() {
        guard mode == .clipboard else { return }
        isActionPanelOpen = false
        isConfirmingClear = true
    }

    func cancelClearClipboard() {
        isConfirmingClear = false
    }

    func clearClipboard(keepPinned: Bool) {
        isConfirmingClear = false
        #if DEBUG
        if isInertForTesting { return }
        #endif
        removeItems { item in
            guard case .clipboard(let entry)? = item.preview else { return false }
            return !(keepPinned && entry.isPinned)
        }
        showToast(L(keepPinned ? "clipboard.clearedKeepPinned" : "clipboard.cleared"))
        Task {
            await ClipboardMonitor.shared.clearHistory(keepPinned: keepPinned)
            refresh()
        }
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
        if let text = axSelection() { return text }
        return NSPasteboard.general.string(forType: .string) ?? ""
    }

    private static func axSelection() -> String? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXElement.application(pid: app.processIdentifier).focusedElement
        guard let text: String = element?.attribute(kAXSelectedTextAttribute), !text.isEmpty else { return nil }
        return text
    }

    static var hasAXSelection: Bool { axSelection() != nil }

    /// Copies the frontmost app's selection with ⌘C and puts the clipboard back.
    /// Nil when nothing was copied (no selection).
    static func copySelection() async -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        ClipboardMonitor.shared.markOwnWrite()
        SyntheticInput.pressKey(KeyboardLayout.keyCode(for: "c") ?? 8, modifiers: .command)
        for _ in 0..<15 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        ClipboardMonitor.shared.markOwnWrite()
        return text
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
