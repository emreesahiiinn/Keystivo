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
import SwiftUI

/// "Gelişmiş Cmd+Tab": an independent window switcher with live previews.
///
/// It never replaces the system switcher; by default it lives on ⌥⇥ and can
/// optionally intercept ⌘⇥ through the event tap when the user opts in.
@Observable
final class SwitcherModel {
    enum Scope: Equatable { case all, frontmostApp }

    private(set) var entries: [WindowInfo] = []
    var selectedIndex = 0
    var groupFilter: AppGroup?
    var thumbnailWidth: CGFloat = 240
    /// Card width actually used (the setting, shrunk to fit small screens).
    var cardWidth: CGFloat = 240
    var showsThumbnails = true
    var openToken = 0
    /// Grid columns currently shown (arrow keys move by a row).
    var columns = 1
    /// True when the pointer (not the keyboard) chose the selection; the grid
    /// then doesn't scroll, so the card stays under the pointer.
    var selectedByPointer = false
    @ObservationIgnored var allEntries: [WindowInfo] = []
    /// Card frames in the panel's top-left coordinate space, for hover selection.
    @ObservationIgnored var cardFrames: [Int: CGRect] = [:]

    var selected: WindowInfo? { entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil }

    func setEntries(_ windows: [WindowInfo]) {
        allEntries = windows
        applyFilter()
    }

    func applyFilter() {
        if let group = groupFilter {
            entries = allEntries.filter { $0.bundleID.map(group.bundleIDs.contains) == true }
        } else {
            entries = allEntries
        }
        selectedIndex = min(selectedIndex, max(entries.count - 1, 0))
    }

    func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedByPointer = false
        selectedIndex = ((selectedIndex + delta) % entries.count + entries.count) % entries.count
    }

    /// ↑/↓: one row up or down, staying in the same column when possible.
    func moveRow(_ direction: Int) {
        guard !entries.isEmpty else { return }
        let target = selectedIndex + direction * max(columns, 1)
        selectedByPointer = false
        if entries.indices.contains(target) {
            selectedIndex = target
        } else if columns <= 1 {
            move(direction)
        } else if direction > 0 {
            // Past the last row: wrap to the top of the same column.
            selectedIndex = selectedIndex % columns
        } else {
            // Above the first row: the last card in this column.
            let column = selectedIndex % columns
            let lastRowStart = (entries.count - 1) / columns * columns
            selectedIndex = min(lastRowStart + column, entries.count - 1)
        }
    }

    /// Selects the card under `point` (panel coordinates, top-left origin).
    func hover(at point: CGPoint) {
        guard let index = cardFrames.first(where: { $0.value.contains(point) })?.key,
              entries.indices.contains(index), index != selectedIndex else { return }
        selectedByPointer = true
        selectedIndex = index
    }

    /// Next window of the same application (⌥` while switching).
    func nextWindowOfSameApp() {
        guard let current = selected else { return }
        let indices = entries.indices.filter { entries[$0].pid == current.pid }
        guard let position = indices.firstIndex(of: selectedIndex), indices.count > 1 else { return }
        selectedIndex = indices[(position + 1) % indices.count]
    }

    func remove(_ window: WindowInfo) {
        allEntries.removeAll { $0 == window }
        applyFilter()
    }
}

final class SwitcherController: EventTapHandler {
    let model = SwitcherModel()
    private unowned let runtime: KeystivoRuntime
    private var panel: FloatingPanel?
    private var holdModifiers: KeyModifiers = []
    private var isOpening = false
    /// Tab/arrow presses that arrive while windows are still loading.
    private var pendingMoves = 0
    /// Pointer position when the switcher opened: hovering only selects after
    /// the pointer actually moves, so a resting mouse doesn't steal the selection.
    private var openPointer: CGPoint?

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
        EventTapManager.shared.add(self)
    }

    var isVisible: Bool { panel?.isVisible == true }

    func settingsChanged() {
        model.thumbnailWidth = runtime.config.switcher.thumbnailWidth
        model.showsThumbnails = runtime.config.switcher.showsThumbnails
        EventTapManager.shared.refresh()
    }

    // MARK: Opening

    func toggle(scope: SwitcherModel.Scope, holdModifiers: KeyModifiers) async {
        if isVisible {
            model.move(holdModifiers.contains(.shift) ? -1 : 1)
            return
        }
        guard !isOpening else {
            pendingMoves += holdModifiers.contains(.shift) ? -1 : 1
            return
        }
        isOpening = true
        pendingMoves = 0
        defer { isOpening = false }
        self.holdModifiers = holdModifiers.subtracting(.shift)
        let settings = runtime.config.switcher
        var options = WindowCatalog.Options()
        options.includeMinimized = settings.includesMinimized
        options.includeHiddenApps = settings.includesHiddenApps
        options.includeOtherSpaces = settings.includesOtherSpaces
        var windows = await WindowCatalog.shared.windows(options: options)
        if scope == .frontmostApp, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            windows = windows.filter { $0.pid == pid }
        }
        // Most recently used first; unknown windows keep window-server order.
        let history = FocusHistory.shared
        windows = windows.enumerated().sorted { lhs, rhs in
            let left = history.rank(of: lhs.element.id)
            let right = history.rank(of: rhs.element.id)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
        if settings.groupsByApp {
            var seen = Set<pid_t>()
            windows = windows.filter { seen.insert($0.pid).inserted }
        }
        guard !windows.isEmpty else {
            runtime.hud.show(symbol: "macwindow", text: L("switcher.noWindows"))
            return
        }
        model.groupFilter = nil
        model.thumbnailWidth = settings.thumbnailWidth
        model.showsThumbnails = settings.showsThumbnails && ThumbnailService.shared.isAvailable
        model.setEntries(windows)
        model.selectedIndex = windows.count > 1 ? 1 : 0
        if pendingMoves != 0 { model.move(pendingMoves) }
        pendingMoves = 0
        present()
        EventTapManager.shared.refresh()
        if model.showsThumbnails {
            Task { await ThumbnailService.shared.load(windows.prefix(30).map(\.id), width: settings.thumbnailWidth) }
        }
        // If the modifier was already released before we finished loading, commit now.
        if !self.holdModifiers.isEmpty, !KeyModifiers(CGEventSource.flagsState(.combinedSessionState)).isSuperset(of: self.holdModifiers) {
            confirm()
        }
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.cardFrames = [:]
        model.selectedByPointer = false
        openPointer = NSEvent.mouseLocation
        resizePanel()
        panel.center(on: NSScreen.underMouse)
        model.openToken += 1
        panel.presentAnimated(makeKey: false, rise: 0)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .modalPanel)
        // Keys arrive through the event tap; the panel never needs focus.
        panel.acceptsKey = false
        panel.host(SwitcherView(model: model, onSelect: { [weak self] index in
            self?.model.selectedIndex = index
            self?.confirm()
        }), size: CGSize(width: 400, height: 200))
        return panel
    }

    func resizePanel() {
        guard let panel, let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        let cardWidth = SwitcherLayout.cardWidth(requested: model.showsThumbnails ? model.thumbnailWidth : 120, screen: screen.visibleFrame.size)
        let layout = SwitcherLayout.layout(count: model.entries.count, cardWidth: cardWidth, showsThumbnails: model.showsThumbnails,
                                           available: CGSize(width: screen.visibleFrame.width * 0.92, height: screen.visibleFrame.height * 0.85))
        model.columns = layout.columns
        model.cardWidth = cardWidth
        panel.setContentSize(layout.size)
        panel.center(on: screen)
    }

    // MARK: Closing

    func confirm() {
        let selected = model.selected
        close()
        selected?.focus()
    }

    func close() {
        panel?.dismissAnimated()
        holdModifiers = []
        EventTapManager.shared.refresh()
    }

    // MARK: Event tap

    var eventTapPriority: Int { 900 }

    var eventTapTypes: Set<CGEventType> {
        if isVisible { return [.keyDown, .flagsChanged, .mouseMoved] }
        return runtime.config.switcher.replacesCommandTab && AXIsProcessTrusted() ? [.keyDown] : []
    }

    func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        let modifiers = KeyModifiers(event.flags).subtracting(.function)
        if type == .mouseMoved {
            if isVisible { pointerMoved() }
            return .pass
        }
        if !isVisible {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            // Keys pressed while the window list is still loading aren't lost.
            if isOpening {
                switch keyCode {
                case kVK_Tab where !modifiers.intersection([.command, .option, .control]).isEmpty:
                    pendingMoves += modifiers.contains(.shift) ? -1 : 1
                    return .consume
                case kVK_RightArrow, kVK_DownArrow:
                    pendingMoves += 1
                    return .consume
                case kVK_LeftArrow, kVK_UpArrow:
                    pendingMoves -= 1
                    return .consume
                default:
                    break
                }
            }
            // Optional ⌘⇥ takeover.
            if keyCode == kVK_Tab, modifiers.subtracting(.shift) == .command {
                Task { await toggle(scope: .all, holdModifiers: modifiers) }
                return .consume
            }
            // ⌘` before the panel appears: same-app windows, like the system switcher.
            if keyCode == kVK_ANSI_Grave, modifiers.subtracting(.shift) == .command, isOpening {
                return .consume
            }
            return .pass
        }
        if type == .flagsChanged {
            if !holdModifiers.isEmpty, !modifiers.isSuperset(of: holdModifiers) { confirm() }
            return .pass
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let shift = modifiers.contains(.shift)
        switch keyCode {
        case kVK_Tab: model.move(shift ? -1 : 1)
        case kVK_RightArrow: model.move(1)
        case kVK_LeftArrow: model.move(-1)
        case kVK_DownArrow: model.moveRow(1)
        case kVK_UpArrow: model.moveRow(-1)
        case kVK_ANSI_Grave: model.nextWindowOfSameApp()
        case kVK_Return, kVK_Space, kVK_ANSI_KeypadEnter: confirm()
        case kVK_Escape: close()
        case kVK_ANSI_W:
            if let window = model.selected { window.element?.close(); model.remove(window); resizePanel() }
        case kVK_ANSI_M:
            if let window = model.selected { window.element?.setMinimized(true) }
        case kVK_ANSI_Q:
            if let window = model.selected {
                NSRunningApplication(processIdentifier: window.pid)?.terminate()
                model.allEntries.filter { $0.pid == window.pid }.forEach(model.remove)
                resizePanel()
            }
        case kVK_ANSI_H:
            if let window = model.selected { NSRunningApplication(processIdentifier: window.pid)?.hide() }
        case kVK_ANSI_G:
            cycleGroupFilter()
        default:
            break
        }
        if model.entries.isEmpty { close() }
        return .consume
    }

    /// Hover selects, like the system switcher, once the pointer has moved.
    private func pointerMoved() {
        guard let panel else { return }
        let location = NSEvent.mouseLocation
        if let start = openPointer {
            guard hypot(location.x - start.x, location.y - start.y) > 3 else { return }
            openPointer = nil
        }
        guard panel.frame.contains(location) else { return }
        model.hover(at: CGPoint(x: location.x - panel.frame.minX, y: panel.frame.maxY - location.y))
    }

    /// Cycles through app groups as a filter ("uygulama grupları").
    private func cycleGroupFilter() {
        let groups = runtime.config.workspace.appGroups
        guard !groups.isEmpty else { return }
        if let current = model.groupFilter, let index = groups.firstIndex(where: { $0.id == current.id }) {
            model.groupFilter = index + 1 < groups.count ? groups[index + 1] : nil
        } else {
            model.groupFilter = groups.first
        }
        model.applyFilter()
        resizePanel()
    }
}

enum SwitcherLayout {
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 22
    /// Room around the grid so the enlarged, glowing selection is never clipped.
    static let inset: CGFloat = 10
    /// Header row (group filter, hints) plus its spacing.
    static let header: CGFloat = 26

    static func cardHeight(width: CGFloat, showsThumbnails: Bool) -> CGFloat {
        showsThumbnails ? width * 0.62 + 36 : 112
    }

    /// Shrinks large thumbnails on small screens so at least two fit side by side.
    static func cardWidth(requested: CGFloat, screen: CGSize) -> CGFloat {
        min(requested, max(110, (screen.width * 0.92 - (padding + inset) * 2 - spacing) / 2))
    }

    static func columns(count: Int, cardWidth: CGFloat, maxWidth: CGFloat) -> Int {
        let fit = Int((maxWidth - (padding + inset) * 2 + spacing) / (cardWidth + spacing))
        return max(1, min(count, fit))
    }

    /// Columns, visible rows and panel size for `count` cards within `available`.
    static func layout(count: Int, cardWidth: CGFloat, showsThumbnails: Bool, available: CGSize) -> (columns: Int, rows: Int, size: CGSize) {
        let columns = columns(count: count, cardWidth: cardWidth, maxWidth: available.width)
        let rows = Int(ceil(Double(max(count, 1)) / Double(columns)))
        let cardHeight = cardHeight(width: cardWidth, showsThumbnails: showsThumbnails)
        let chrome = (padding + inset) * 2 + header
        let fittingRows = max(1, Int((available.height - chrome + spacing) / (cardHeight + spacing)))
        let visibleRows = min(rows, fittingRows)
        var height = CGFloat(visibleRows) * cardHeight + CGFloat(visibleRows - 1) * spacing + chrome
        // A partially visible next row hints that the grid scrolls.
        if rows > visibleRows { height = min(height + cardHeight * 0.35, available.height) }
        let width = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * spacing + (padding + inset) * 2
        return (columns, visibleRows, CGSize(width: max(width, 320), height: height))
    }
}
