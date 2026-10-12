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
import SwiftUI

extension LauncherModel {
    // MARK: Synchronous providers

    func synchronousItems(for text: String) -> [LauncherItem] {
        switch mode {
        case .root:
            if text.isEmpty { return emptyStateItems() }
            var results: [LauncherItem] = []
            results += aliasItems(text)
            results += calculatorItems(text)
            results += worldItems(text)
            results += quicklinkItems(text)
            results += appItems(text)
            results += commandItems(text)
            results += workflowItems(text)
            results += windowItems(text, section: .windows, minimumLength: 2)
            results += snippetItems(text, section: .snippets)
            results += fallbackItems(text)
            return results
        case .windows:
            return windowItems(text, section: .results, minimumLength: 0)
        case .snippets:
            return snippetItems(text, section: .results)
        case .textActions:
            return textActionItems(text)
        case .emoji:
            return emojiItems(text)
        case .menuItems:
            return menuItemItems(text)
        case .processes:
            return processItems(text)
        case .schedule:
            return scheduleItems(text)
        case .captures:
            return captureItems(text)
        case .pluginOutput:
            guard !text.isEmpty else { return pluginResultItems }
            return pluginResultItems.compactMap { item in
                guard let match = FuzzyMatcher.bestMatch(text, title: item.title, alternates: [item.subtitle ?? ""]) else { return nil }
                var copy = item
                copy.score = match.score
                copy.highlight = match.matchedOffsets
                return copy
            }
        case .clipboard, .files:
            return []
        }
    }

    func asynchronousItems(for text: String) async -> [LauncherItem] {
        switch mode {
        case .root:
            let files = await FileSearch.shared.search(text, limit: 6)
            return files.map { fileItem($0, section: .files, score: 40) }
        case .files:
            let files = await FileSearch.shared.search(text, limit: 40, recentsWhenEmpty: true)
            return files.enumerated().map { index, file in fileItem(file, section: .results, score: Double(1000 - index)) }
        case .clipboard:
            #if DEBUG
            if isInertForTesting {
                return (1...10).map { index in
                    clipboardItem(ClipboardItem(id: Int64(index), kind: .text, text: "Sample clipboard text \(index)",
                                                sourceBundleID: "com.apple.Safari", createdAt: .now - Double(index) * 600,
                                                lastUsedAt: .now - Double(index - 1) * 600))
                }
            }
            #endif
            let entries = await ClipboardMonitor.shared.items(matching: text, limit: 300)
            return entries.map(clipboardItem)
        default:
            return []
        }
    }

    // MARK: Empty state

    private func emptyStateItems() -> [LauncherItem] {
        var results: [LauncherItem] = []
        if runtime.config.launcher.showsRecent {
            let recent = runtime.config.usage
                .sorted { $0.value.boost() > $1.value.boost() }
                .prefix(6)
            for (key, stats) in recent {
                if let app = AppCatalog.shared.apps.first(where: { ($0.bundleID ?? $0.path) == key }) {
                    var item = appItem(app, score: stats.boost(), highlight: [])
                    item.section = .recent
                    results.append(item)
                } else if let descriptor = ActionRegistry.shared.descriptor(key.replacingOccurrences(of: "action:", with: "")), key.hasPrefix("action:") {
                    var item = commandItem(descriptor, score: stats.boost(), highlight: [])
                    item.section = .recent
                    results.append(item)
                }
            }
        }
        let suggestions = ["clipboard.history", "windows.switcher", "navigation.hints", "audio.showMixer", "focus.toggle", "launcher.files", "app.settings"]
        for (index, id) in suggestions.enumerated() {
            guard let descriptor = ActionRegistry.shared.descriptor(id), !results.contains(where: { $0.id == "action:\(id)" }) else { continue }
            var item = commandItem(descriptor, score: Double(100 - index), highlight: [])
            item.section = .suggestions
            results.append(item)
        }
        return results
    }

    // MARK: Calculator & conversion

    private func calculatorItems(_ text: String) -> [LauncherItem] {
        guard runtime.config.launcher.showsCalculator else { return [] }
        let locale = Localizer.shared.locale
        if let conversion = UnitConverter.convert(text) {
            let result = Calculator.format(conversion.result, locale: locale)
            let display = "\(result) \(conversion.toSymbol)"
            return [resultItem(id: "convert", title: display, subtitle: "\(Calculator.format(conversion.value, locale: locale)) \(conversion.fromSymbol)", symbol: "arrow.left.arrow.right", copyValue: result)]
        }
        guard Calculator.looksLikeExpression(text), let value = try? Calculator.evaluate(text) else { return [] }
        let formatted = Calculator.format(value, locale: locale)
        let raw = value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        return [resultItem(id: "calc", title: formatted, subtitle: text, symbol: "equal.square", copyValue: raw)]
    }

    private func resultItem(id: String, title: String, subtitle: String, symbol: String, copyValue: String) -> LauncherItem {
        LauncherItem(
            id: id, title: title, subtitle: subtitle, icon: .symbol(symbol, .orange), accessory: .text(L("launcher.copy")),
            section: .calculator, score: 10_000,
            primary: LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc") { Pasteboard.copy(copyValue) },
            actions: [
                LauncherAction(title: L("launcher.action.paste"), symbol: "doc.on.clipboard", shortcut: .commandReturn) { await Pasteboard.paste(copyValue) },
            ]
        )
    }

    // MARK: Apps

    private func appItems(_ text: String) -> [LauncherItem] {
        AppCatalog.shared.search(text, usage: runtime.config.usage, limit: 10).map { match in
            appItem(match.app, score: match.score, highlight: match.match.matchedOffsets)
        }
    }

    func appItem(_ app: AppRecord, score: Double, highlight: [Int]) -> LauncherItem {
        let running = app.bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        var actions: [LauncherAction] = [
            LauncherAction(title: L("launcher.action.revealInFinder"), symbol: "folder", shortcut: .commandReturn) {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            },
            LauncherAction(title: L("launcher.action.copyPath"), symbol: "doc.on.doc", shortcut: .command("c", shift: true)) { Pasteboard.copy(app.path) },
        ]
        if running, let bundleID = app.bundleID {
            actions.append(LauncherAction(title: L("launcher.action.hideApp"), symbol: "eye.slash", shortcut: .command("h")) {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.hide() }
            })
            actions.append(LauncherAction(title: L("launcher.action.quitApp"), symbol: "xmark.circle", shortcut: .command("q")) {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
            })
            actions.append(LauncherAction(title: L("launcher.action.forceQuit"), symbol: "exclamationmark.octagon", shortcut: .command("q", shift: true), isDestructive: true) {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.forceTerminate() }
            })
        }
        if let bundleID = app.bundleID {
            actions.append(LauncherAction(title: L("launcher.action.copyBundleID"), symbol: "number", shortcut: .command("b")) { Pasteboard.copy(bundleID) })
        }
        return LauncherItem(
            id: "app:\(app.path)", title: app.name, subtitle: nil, icon: .app(bundleID: app.bundleID, path: app.path),
            accessory: .text(running ? L("launcher.accessory.running") : L("launcher.accessory.application")),
            section: .apps, score: score, highlight: highlight,
            primary: LauncherAction(title: L("launcher.action.open"), symbol: "arrow.up.forward.app") {
                try? await AppControl.open(url: app.url)
            },
            actions: actions, usageKey: app.bundleID ?? app.path
        )
    }

    // MARK: Commands

    private func commandItems(_ text: String) -> [LauncherItem] {
        ActionRegistry.shared.descriptors.values.compactMap { descriptor in
            guard descriptor.showsInLauncher, descriptor.isRunnableWithoutInput || descriptor.parameters.allSatisfy({ $0.isOptional || $0.defaultValue != nil || $0.key == "query" }) else { return nil }
            let title = L(descriptor.titleKey)
            let alternates = descriptor.keywords + [L(descriptor.category.titleKey)]
            let boost = runtime.config.usage["action:\(descriptor.id)"]?.boost() ?? 0
            if let match = FuzzyMatcher.bestMatch(text, title: title, alternates: alternates) {
                return commandItem(descriptor, score: match.score * 0.95 + boost, highlight: match.matchedOffsets)
            }
            // "translate hello": the command's name, then its argument.
            guard descriptor.parameters.contains(where: { $0.key == "query" }) else { return nil }
            let words = text.split(separator: " ", omittingEmptySubsequences: true)
            for count in stride(from: words.count - 1, through: 1, by: -1) {
                let name = words[..<count].joined(separator: " ")
                guard let match = FuzzyMatcher.bestMatch(name, title: title, alternates: alternates) else { continue }
                let argument = words[count...].joined(separator: " ")
                return commandItem(descriptor, score: match.score * 0.95 + boost, highlight: match.matchedOffsets, argument: argument)
            }
            return nil
        }
    }

    func commandItem(_ descriptor: ActionDescriptor, score: Double, highlight: [Int], argument: String? = nil) -> LauncherItem {
        let combo = runtime.config.hotkeys.first { $0.isEnabled && $0.actions.count == 1 && $0.actions[0].actionID == descriptor.id }?.combo
        let acceptsQuery = descriptor.parameters.contains { $0.key == "query" }
        return LauncherItem(
            id: "action:\(descriptor.id)", title: L(descriptor.titleKey),
            subtitle: argument.map { "→ “\($0)”" } ?? L(descriptor.category.titleKey),
            icon: .symbol(descriptor.symbolName, color(for: descriptor.category)),
            accessory: combo.map { .shortcut($0) } ?? .text(L("launcher.accessory.command")),
            section: .commands, score: score, highlight: highlight,
            primary: LauncherAction(title: L("launcher.action.run"), symbol: "play", dismisses: !Self.keepsOpen(descriptor.id)) {
                var invocation = descriptor.defaultInvocation()
                if acceptsQuery, let argument, !argument.isEmpty {
                    invocation.arguments["query"] = .string(argument)
                }
                // Give the launcher time to close so actions target the previous app.
                try? await Task.sleep(for: .milliseconds(Self.keepsOpen(descriptor.id) ? 0 : 90))
                try? await ActionRegistry.shared.perform(invocation, context: ActionContext(source: .launcher))
            },
            actions: [
                LauncherAction(title: L("launcher.action.assignShortcut"), symbol: "command", shortcut: .command("k", shift: true)) {
                    KeystivoRuntime.shared.windowsUI.showSettings(section: .shortcuts, newBindingFor: descriptor.id)
                },
            ],
            usageKey: "action:\(descriptor.id)", requiresConfirmation: descriptor.requiresConfirmation
        )
    }

    /// Commands that switch the launcher into another mode instead of closing it.
    static func keepsOpen(_ actionID: String) -> Bool {
        ["clipboard.history", "snippets.show", "launcher.files", "launcher.windows", "launcher.quickActions",
         "launcher.emoji", "launcher.menuItems", "launcher.processes", "launcher.schedule", "tools.captureHistory"].contains(actionID)
            || actionID.hasPrefix("plugin.")
    }

    private func color(for category: ActionCategory) -> Color {
        switch category {
        case .windows: .blue
        case .apps: .indigo
        case .audio: .pink
        case .navigation: .teal
        case .clipboard: .orange
        case .launcher: .gray
        case .workspace: .purple
        case .automation: .yellow
        case .input: .mint
        case .system: .gray
        case .power: .green
        case .plugins: .cyan
        }
    }

    // MARK: Workflows

    private func workflowItems(_ text: String) -> [LauncherItem] {
        runtime.config.automation.workflows.compactMap { workflow in
            guard workflow.showsInLauncher, let match = FuzzyMatcher.bestMatch(text, title: workflow.name, alternates: [workflow.notes]) else { return nil }
            return workflowItem(workflow, score: match.score, highlight: match.matchedOffsets)
        }
    }

    func workflowItem(_ workflow: Workflow, score: Double, highlight: [Int]) -> LauncherItem {
            LauncherItem(
                id: "workflow:\(workflow.id)", title: workflow.name, subtitle: L("launcher.accessory.workflow"),
                icon: .symbol(workflow.symbolName, .yellow), accessory: .text(L("launcher.accessory.workflow")),
                section: .workflows, score: score, highlight: highlight,
                primary: LauncherAction(title: L("launcher.action.run"), symbol: "play") {
                    try? await Task.sleep(for: .milliseconds(90))
                    AutomationEngine.shared.run(workflow, trigger: "launcher")
                },
                actions: [
                    LauncherAction(title: L("launcher.action.edit"), symbol: "pencil", shortcut: .command("e")) {
                        KeystivoRuntime.shared.windowsUI.showSettings(section: .automation)
                    },
                ],
                usageKey: "workflow:\(workflow.id)"
            )
    }

    // MARK: Windows

    private func windowItems(_ text: String, section: LauncherSection, minimumLength: Int) -> [LauncherItem] {
        guard section == .results || (runtime.config.launcher.searchesWindows && text.count >= minimumLength) else { return [] }
        return windowCache.enumerated().compactMap { index, window in
            let score: Double
            var highlight: [Int] = []
            if text.isEmpty {
                score = Double(10_000 - index)
            } else {
                guard let match = FuzzyMatcher.bestMatch(text, title: window.displayTitle, alternates: [window.appName]) else { return nil }
                score = match.score * (section == .windows ? 0.8 : 1)
                highlight = match.matchedOffsets
            }
            var subtitle = window.appName
            if window.isMinimized { subtitle += " · " + L("switcher.minimized") }
            if window.isOnOtherSpace { subtitle += " · " + L("switcher.otherSpace") }
            return LauncherItem(
                id: "window:\(window.pid):\(window.id)", title: window.displayTitle, subtitle: subtitle,
                icon: .app(bundleID: window.bundleID, path: nil), accessory: .text(L("launcher.accessory.window")),
                section: section, score: score, highlight: highlight,
                primary: LauncherAction(title: L("launcher.action.focusWindow"), symbol: "macwindow") { window.focus() },
                actions: [
                    LauncherAction(title: L("launcher.action.closeWindow"), symbol: "xmark.square", shortcut: .command("w"), dismisses: false) { [weak self] in
                        window.element?.close()
                        self?.windowCache.removeAll { $0.id == window.id }
                        self?.refresh()
                    },
                    LauncherAction(title: L("launcher.action.minimizeWindow"), symbol: "minus.square", shortcut: .command("m"), dismisses: false) {
                        window.element?.setMinimized(true)
                    },
                    LauncherAction(title: L("launcher.action.quitApp"), symbol: "xmark.circle", shortcut: .command("q")) {
                        NSRunningApplication(processIdentifier: window.pid)?.terminate()
                    },
                ]
            )
        }
    }

    // MARK: Snippets

    private func snippetItems(_ text: String, section: LauncherSection) -> [LauncherItem] {
        guard section == .results || !text.isEmpty else { return [] }
        return runtime.config.snippets.snippets.compactMap { snippet in
            var score = 0.0
            var highlight: [Int] = []
            if !text.isEmpty {
                let alternates = section == .snippets ? [snippet.keyword] : [snippet.keyword, snippet.collection, snippet.content]
                guard let match = FuzzyMatcher.bestMatch(text, title: snippet.name, alternates: alternates) else { return nil }
                score = match.score * (section == .snippets ? 0.7 : 1)
                highlight = match.matchedOffsets
            }
            return LauncherItem(
                id: "snippet:\(snippet.id)", title: snippet.name, subtitle: snippet.keyword.isEmpty ? snippet.collection : snippet.keyword,
                icon: .symbol("text.quote", .orange), accessory: .text(snippet.keyword),
                section: section, score: score, highlight: highlight,
                primary: LauncherAction(title: L("launcher.action.insert"), symbol: "text.insert") {
                    try? await Task.sleep(for: .milliseconds(120))
                    await SnippetExpander.insert(snippet.content)
                },
                actions: [
                    LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc", shortcut: .command("c")) {
                        Pasteboard.copy(SnippetRenderer.render(snippet.content, clipboard: NSPasteboard.general.string(forType: .string), locale: Localizer.shared.locale).text)
                    },
                    LauncherAction(title: L("launcher.action.edit"), symbol: "pencil", shortcut: .command("e")) {
                        KeystivoRuntime.shared.windowsUI.showSettings(section: .snippets)
                    },
                ],
                preview: .text(snippet.content)
            )
        }
    }

    // MARK: Fallbacks

    private func fallbackItems(_ text: String) -> [LauncherItem] {
        var items: [LauncherItem] = []
        let template = runtime.config.launcher.webSearchTemplate
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: template.replacingOccurrences(of: "%@", with: encoded)) {
            items.append(LauncherItem(
                id: "fallback:web", title: L("launcher.fallback.web", text), subtitle: url.host, icon: .symbol("globe", .blue),
                section: .fallback, score: 1,
                primary: LauncherAction(title: L("launcher.action.open"), symbol: "safari") { NSWorkspace.shared.open(url) }
            ))
        }
        if let define = dictionaryItem(text) { items.append(define) }
        items.append(LauncherItem(
            id: "fallback:files", title: L("launcher.fallback.files", text), icon: .symbol("doc.text.magnifyingglass", .gray),
            section: .fallback, score: 0.9,
            primary: LauncherAction(title: L("launcher.action.search"), symbol: "magnifyingglass", dismisses: false) { [weak self] in
                self?.open(mode: .files)
                self?.query = text
            }
        ))
        items.append(LauncherItem(
            id: "fallback:clipboard", title: L("launcher.fallback.clipboard", text), icon: .symbol("clipboard", .orange),
            section: .fallback, score: 0.8,
            primary: LauncherAction(title: L("launcher.action.search"), symbol: "magnifyingglass", dismisses: false) { [weak self] in
                self?.open(mode: .clipboard)
                self?.query = text
            }
        ))
        return items
    }

    // MARK: Files

    func fileItem(_ file: FileResult, section: LauncherSection, score: Double) -> LauncherItem {
        LauncherItem(
            id: "file:\(file.path)", title: file.name, subtitle: file.parentPath, icon: .file(file.path),
            accessory: .text(file.isDirectory ? L("launcher.accessory.folder") : L("launcher.accessory.file")),
            section: section, score: score,
            primary: LauncherAction(title: L("launcher.action.open"), symbol: "arrow.up.forward.square") { NSWorkspace.shared.open(file.url) },
            actions: [
                LauncherAction(title: L("launcher.action.revealInFinder"), symbol: "folder", shortcut: .commandReturn) {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                },
                LauncherAction(title: L("launcher.action.copyPath"), symbol: "doc.on.doc", shortcut: .command("c", shift: true)) { Pasteboard.copy(file.path) },
                LauncherAction(title: L("launcher.action.copyFile"), symbol: "doc.on.clipboard", shortcut: .command("c")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([file.url as NSURL])
                },
                LauncherAction(title: L("launcher.action.openInTerminal"), symbol: "terminal", shortcut: .command("t")) {
                    let directory = file.isDirectory ? file.url : file.url.deletingLastPathComponent()
                    if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
                    }
                },
                LauncherAction(title: L("launcher.action.moveToTrash"), symbol: "trash", shortcut: .commandDelete, isDestructive: true) {
                    try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                },
            ]
        )
    }

    // MARK: Clipboard

    func clipboardItem(_ entry: ClipboardItem) -> LauncherItem {
        let monitor = ClipboardMonitor.shared
        let icon: LauncherItem.Icon = switch entry.kind {
        case .image: ClipboardThumbnails.thumbnail(for: entry).map(LauncherItem.Icon.image) ?? .symbol("photo", .purple)
        case .file: entry.filePaths.first.map(LauncherItem.Icon.file) ?? .symbol("doc", .gray)
        case .color: .color(entry.text)
        default: .symbol(entry.kind.symbolName, entry.isPinned ? .orange : .gray)
        }
        let source = entry.sourceBundleID.flatMap(AppDisplayName.name(forBundleID:))
        let relative = RelativeDateTimeFormatter()
        relative.locale = Localizer.shared.locale
        relative.dateTimeStyle = .named  // "now" rather than "in 0 seconds"
        let now = Date.now
        let subtitle = [source, relative.localizedString(for: min(entry.lastUsedAt, now), relativeTo: now)].compactMap { $0 }.joined(separator: " · ")
        let pastes = runtime.config.clipboard.pastesDirectly
        return LauncherItem(
            id: "clip:\(entry.id)", title: entry.preview.isEmpty ? L("clipboard.kind.\(entry.kind.rawValue)") : entry.preview,
            subtitle: subtitle, icon: icon, accessory: entry.isPinned ? .text("📌") : nil,
            section: .clipboard, score: 0,
            primary: LauncherAction(title: L(pastes ? "launcher.action.paste" : "launcher.action.copy"), symbol: "doc.on.clipboard") {
                if pastes { monitor.paste(entry) } else { monitor.copy(entry) }
            },
            actions: [
                LauncherAction(title: L("launcher.action.pastePlain"), symbol: "doc.plaintext", shortcut: .commandReturn) { monitor.paste(entry, plainText: true) },
                LauncherAction(title: L(pastes ? "launcher.action.copy" : "launcher.action.paste"), symbol: "doc.on.doc", shortcut: .command("c")) {
                    if pastes { monitor.copy(entry) } else { monitor.paste(entry) }
                },
                LauncherAction(title: L(entry.isPinned ? "launcher.action.unpin" : "launcher.action.pin"), symbol: "pin", shortcut: .command("p"), dismisses: false) { [weak self] in
                    await monitor.togglePin(entry)
                    self?.refresh()
                },
                LauncherAction(title: L("launcher.action.delete"), symbol: "trash", shortcut: .commandDelete, dismisses: false, isDestructive: true) { [weak self] in
                    // The row goes away at once; the store follows.
                    self?.removeItems { $0.id == "clip:\(entry.id)" }
                    self?.showToast(L("clipboard.deleted"))
                    await monitor.delete(entry)
                },
                LauncherAction(title: L("clipboard.clearHistory"), symbol: "trash.slash", shortcut: .commandShiftDelete, dismisses: false, isDestructive: true) { [weak self] in
                    self?.requestClearClipboard()
                },
            ],
            preview: .clipboard(entry)
        )
    }

    // MARK: Text actions

    private func textActionItems(_ text: String) -> [LauncherItem] {
        let input = textInput
        var items: [LauncherItem] = []
        let stats = TextStatistics(input)
        items.append(LauncherItem(
            id: "text:stats", title: L("text.stats", stats.characters, stats.words, stats.lines), icon: .symbol("textformat.123", .gray),
            section: .results, score: 0,
            primary: LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc") { Pasteboard.copy("\(stats.words)") }
        ))
        // On-device translation into the interface language (and English).
        var targets = [Localizer.shared.languageCode]
        if Localizer.shared.languageCode != "en" { targets.append("en") }
        for code in targets {
            let language = Locale.Language(identifier: code)
            let name = Localizer.shared.locale.localizedString(forIdentifier: code) ?? code
            let title = L("text.translateTo", name)
            if !text.isEmpty, FuzzyMatcher.match(text, in: title) == nil { continue }
            items.append(LauncherItem(
                id: "text:translate:\(code)", title: title, subtitle: L("text.translateSubtitle"),
                icon: .symbol("translate", .blue), section: .results, score: 0,
                primary: LauncherAction(title: L("text.translate"), symbol: "translate", dismisses: false) { [weak self] in
                    self?.translate(input, to: language)
                }
            ))
        }
        for transform in TextTransform.allCases {
            let title = L(transform.titleKey)
            if !text.isEmpty, FuzzyMatcher.match(text, in: title) == nil { continue }
            guard let output = transform.apply(input, locale: Localizer.shared.locale) else { continue }
            items.append(LauncherItem(
                id: "text:\(transform.rawValue)", title: title, subtitle: String(output.prefix(80)).replacingOccurrences(of: "\n", with: " ⏎ "),
                icon: .symbol(transform.symbolName, .teal), section: .results, score: 0,
                primary: LauncherAction(title: L("launcher.action.replace"), symbol: "arrow.2.squarepath") {
                    try? await Task.sleep(for: .milliseconds(100))
                    await Pasteboard.paste(output)
                },
                actions: [LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc", shortcut: .command("c")) { Pasteboard.copy(output) }],
                preview: .text(output)
            ))
        }
        return items
    }

    // MARK: Plugins

    func pluginLauncherItem(_ item: PluginItem, index: Int) -> LauncherItem {
        let action: LauncherAction
        if let pluginAction = item.action {
            let value = pluginAction.value
            switch pluginAction.type {
            case .open:
                action = LauncherAction(title: L("launcher.action.open"), symbol: "arrow.up.forward") {
                    if let url = URL(string: value), url.scheme != nil { NSWorkspace.shared.open(url) } else { NSWorkspace.shared.open(URL(fileURLWithPath: (value as NSString).expandingTildeInPath)) }
                }
            case .copy:
                action = LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc") { Pasteboard.copy(value) }
            case .paste:
                action = LauncherAction(title: L("launcher.action.paste"), symbol: "doc.on.clipboard") { await Pasteboard.paste(value) }
            case .notify:
                action = LauncherAction(title: L("launcher.action.run"), symbol: "bell") { KeystivoRuntime.shared.hud.show(symbol: "bell", text: value) }
            case .run:
                action = LauncherAction(title: L("launcher.action.run"), symbol: "play") {
                    ActionRegistry.shared.run(ActionInvocation(value), source: .plugin)
                }
            }
        } else {
            action = LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc") { Pasteboard.copy(item.title) }
        }
        return LauncherItem(
            id: "plugin-item:\(index):\(item.id)", title: item.title, subtitle: item.subtitle,
            icon: .symbol(item.icon ?? "puzzlepiece", .cyan), section: .results, score: Double(1000 - index), primary: action
        )
    }
}

/// Pasteboard helpers used across the launcher.
enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        KeystivoRuntime.shared.hud.show(symbol: "doc.on.doc", text: L("launcher.copied"))
    }

    static func paste(_ text: String) async {
        try? await Task.sleep(for: .milliseconds(80))
        await SnippetExpander.insert(text, renderingPlaceholders: false)
    }
}


/// Small list icons for clipboard images, decoded once (full images can be many megabytes).
enum ClipboardThumbnails {
    private static var cache: [Int64: NSImage] = [:]

    static func thumbnail(for entry: ClipboardItem) -> NSImage? {
        if let cached = cache[entry.id] { return cached }
        guard let data = entry.data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        if cache.count > 400 { cache.removeAll() }
        cache[entry.id] = image
        return image
    }
}
