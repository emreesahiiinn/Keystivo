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

enum HintMode { case click, search, scroll }

/// Observable state rendered by the overlay windows.
@Observable
final class HintsModel {
    var elements: [NavigableElement] = []
    var labels: [String] = []
    var visible: Set<Int> = []
    var typed = ""
    var isSearching = false
    var searchResults: [Int] = []
    var searchSelection = 0
    var scrollSelection: Int?
    var isScrollMode = false
    var style: HintStyle = .accent
    var fontSize: CGFloat = 12
    var shakeToken = 0
}

/// Keyboard navigation ("ekrandaki öğelere harfli etiketler", "klavyeyle tıklama",
/// "klavyeyle kaydırma"). Keys are captured through the shared event tap only
/// while a session is active.
final class HintsController: EventTapHandler {
    let model = HintsModel()
    private unowned let runtime: KeystivoRuntime
    private var overlays: [OverlayWindow] = []
    private var matcher: HintMatcher?
    private var isActive = false
    private var mode: HintMode = .click
    private var isCollecting = false

    init(runtime: KeystivoRuntime) {
        self.runtime = runtime
        EventTapManager.shared.add(self)
    }

    // MARK: Session

    func start(mode: HintMode) async {
        if isActive { stop(); return }
        guard !isCollecting else { return }
        isCollecting = true
        defer { isCollecting = false }
        self.mode = mode
        let settings = runtime.config.navigation
        var options = CollectorOptions()
        options.includeMenuBar = settings.includesMenuBar
        options.includeDock = settings.includesDock
        // Searching needs names, so give big pages a little more time.
        if mode == .search { options.timeBudget = .milliseconds(800) }
        let elements = await ElementCollector.collect(mode: mode == .scroll ? .scroll : .click, options: options)
        guard !elements.isEmpty else {
            runtime.hud.show(symbol: "rectangle.dashed", text: L(mode == .scroll ? "hints.noScrollAreas" : "hints.noElements"), style: .warning)
            return
        }
        let labels = HintLabelGenerator.labels(count: elements.count, alphabet: settings.alphabet)
        var matcher = HintMatcher(labels: labels, titles: elements.map(\.title))
        if mode == .search { matcher.setMode(.search) }
        self.matcher = matcher

        model.elements = elements
        model.labels = labels.map { $0.uppercased() }
        model.typed = ""
        model.isScrollMode = mode == .scroll
        model.scrollSelection = nil
        model.style = settings.hintStyle
        model.fontSize = settings.hintSize
        model.isSearching = mode == .search
        update(matcher.evaluate())

        if mode == .scroll, elements.count == 1 { selectScrollArea(0) }
        showOverlays()
        isActive = true
        EventTapManager.shared.refresh()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        matcher = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        model.elements = []
        EventTapManager.shared.refresh()
    }

    private func showOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            let hosting = NSHostingView(rootView: HintsOverlayView(model: model, screenFrame: ScreenGeometry.frameAX(of: screen)).localizedRoot())
            hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
            window.contentView = hosting
            window.orderFrontRegardless()
            return window
        }
    }

    private func update(_ outcome: HintMatcher.Outcome) {
        guard let matcher else { return }
        model.typed = matcher.typed
        model.isSearching = matcher.mode == .search
        switch outcome {
        case .pending(let visible):
            model.visible = Set(visible)
            if matcher.mode == .search {
                model.searchResults = visible
                model.searchSelection = matcher.searchSelection
            }
        case .noMatch:
            model.shakeToken += 1
            if matcher.mode == .labels {
                // Wrong letter: start over instead of leaving the user stuck.
                var reset = matcher
                while !reset.typed.isEmpty { _ = reset.backspace() }
                self.matcher = reset
                model.typed = ""
                model.visible = Set(model.elements.indices)
            } else {
                model.searchResults = []
                model.visible = []
            }
        case .matched:
            break
        }
    }

    private func activate(index: Int, modifiers: KeyModifiers) {
        guard model.elements.indices.contains(index) else { return }
        if mode == .scroll {
            selectScrollArea(index)
            return
        }
        let element = model.elements[index]
        stop()
        // Let the overlay disappear before clicking through.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            HintActuator.activate(element, with: HintActivation(modifiers: modifiers))
        }
    }

    private func selectScrollArea(_ index: Int) {
        model.scrollSelection = index
        model.visible = [index]
        ScrollActuator.focus(model.elements[index])
    }

    // MARK: Event tap

    var eventTapPriority: Int { 1000 }

    var eventTapTypes: Set<CGEventType> {
        isActive ? [.keyDown, .leftMouseDown, .rightMouseDown] : []
    }

    func handleTapEvent(_ event: CGEvent, type: CGEventType) -> EventTapDisposition {
        guard isActive, var matcher else { return .pass }
        if type != .keyDown {
            stop()
            return .pass
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = KeyModifiers(event.flags).subtracting(.function)

        if keyCode == kVK_Escape {
            stop()
            return .consume
        }
        if mode == .scroll, let selection = model.scrollSelection {
            handleScrollKey(keyCode, modifiers: modifiers, area: selection)
            return .consume
        }
        switch keyCode {
        case kVK_Delete:
            update(matcher.backspace())
        case kVK_Tab where mode != .scroll:
            matcher.setMode(matcher.mode == .labels ? .search : .labels)
            update(matcher.evaluate())
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if case .matched(let index) = matcher.confirm() {
                self.matcher = matcher
                activate(index: index, modifiers: modifiers)
                return .consume
            }
        case kVK_DownArrow where matcher.mode == .search:
            update(matcher.moveSelection(by: 1))
        case kVK_UpArrow where matcher.mode == .search:
            update(matcher.moveSelection(by: -1))
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            break
        default:
            // ⌘/⌃ chords are shortcuts, not query text.
            if matcher.mode == .search, !modifiers.isDisjoint(with: [.command, .control]) { return .consume }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
            guard length > 0, let character = String(utf16CodeUnits: chars, count: length).lowercased().first,
                  HintMatcher.isTypable(character) else { return .consume }
            if character == "/" && matcher.mode == .labels {
                matcher.setMode(.search)
                update(matcher.evaluate())
                break
            }
            guard matcher.mode == .search || character.isLetter else { return .consume }
            let outcome = matcher.type(character)
            if case .matched(let index) = outcome {
                self.matcher = matcher
                activate(index: index, modifiers: modifiers)
                return .consume
            }
            update(outcome)
        }
        self.matcher = matcher
        return .consume
    }

    private func handleScrollKey(_ keyCode: Int, modifiers: KeyModifiers, area: Int) {
        let element = model.elements[area]
        let step = Int32(runtime.config.navigation.scrollStep)
        switch keyCode {
        case kVK_ANSI_J, kVK_DownArrow: ScrollActuator.scroll(.down, in: element, step: step)
        case kVK_ANSI_K, kVK_UpArrow: ScrollActuator.scroll(.up, in: element, step: step)
        case kVK_ANSI_H, kVK_LeftArrow: ScrollActuator.scroll(.left, in: element, step: step)
        case kVK_ANSI_L, kVK_RightArrow: ScrollActuator.scroll(.right, in: element, step: step)
        case kVK_ANSI_D, kVK_Space, kVK_PageDown: ScrollActuator.scroll(.pageDown, in: element)
        case kVK_ANSI_U, kVK_PageUp: ScrollActuator.scroll(.pageUp, in: element)
        case kVK_ANSI_G: ScrollActuator.scroll(modifiers.contains(.shift) ? .bottom : .top, in: element)
        case kVK_Tab:
            let next = (area + (modifiers.contains(.shift) ? model.elements.count - 1 : 1)) % model.elements.count
            selectScrollArea(next)
        default:
            break
        }
    }
}
