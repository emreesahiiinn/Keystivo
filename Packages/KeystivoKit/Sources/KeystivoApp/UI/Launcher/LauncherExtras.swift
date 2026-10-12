import AppKit
import CoreServices
import KeystivoAccessibility
import KeystivoCore
import KeystivoSearch
import KeystivoSystem
import KeystivoTools
import SwiftUI

/// Raycast-style extras: quicklinks, emoji & symbols, menu item search,
/// processes, currency and world clock, dictionary.
extension LauncherModel {
    // MARK: Quicklinks

    /// "yt cats" runs the YouTube quicklink; "youtube" finds it by name.
    func quicklinkItems(_ text: String) -> [LauncherItem] {
        let links = runtime.config.launcher.quicklinks
        guard !links.isEmpty, !text.isEmpty else { return [] }
        let clipboard = NSPasteboard.general.string(forType: .string)
        var items: [LauncherItem] = []
        // Keyword plus query: "g swift actors".
        if let space = text.firstIndex(of: " ") {
            let keyword = text[..<space].lowercased()
            let argument = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces)
            for link in links where link.keyword.lowercased() == keyword && link.takesQuery && !argument.isEmpty {
                guard let url = link.resolvedURL(query: argument, clipboard: clipboard) else { continue }
                items.append(quicklinkItem(link, title: L("quicklinks.searchIn", link.name, argument), url: url, score: 20_000))
            }
            if !items.isEmpty { return items }
        }
        for link in links {
            let exactKeyword = link.keyword.lowercased() == text.lowercased()
            guard exactKeyword || FuzzyMatcher.bestMatch(text, title: link.name, alternates: [link.keyword]) != nil else { continue }
            let match = FuzzyMatcher.bestMatch(text, title: link.name, alternates: [link.keyword])
            let score = exactKeyword ? 15_000 : (match?.score ?? 0)
            if link.takesQuery {
                // Selecting it types the keyword so the query can follow.
                var item = LauncherItem(
                    id: "quicklink:\(link.id)", title: link.name, subtitle: L("quicklinks.typeQuery", link.keyword),
                    icon: .symbol("link", .blue), accessory: .text(link.keyword),
                    section: .quicklinks, score: score, highlight: match?.matchedOffsets ?? [],
                    primary: LauncherAction(title: L("quicklinks.enterQuery"), symbol: "text.cursor", dismisses: false) { [weak self] in
                        self?.query = link.keyword + " "
                    },
                    usageKey: "quicklink:\(link.id)"
                )
                if let url = link.resolvedURL(query: "", clipboard: clipboard) {
                    item.actions = [LauncherAction(title: L("quicklinks.openWithoutQuery"), symbol: "safari", shortcut: .commandReturn) { [weak self] in
                        self?.open(url, with: link.appBundleID)
                    }]
                }
                items.append(item)
            } else if let url = link.resolvedURL(query: "", clipboard: clipboard) {
                items.append(quicklinkItem(link, title: link.name, url: url, score: score, highlight: match?.matchedOffsets ?? []))
            }
        }
        return items
    }

    private func quicklinkItem(_ link: Quicklink, title: String, url: URL, score: Double, highlight: [Int] = []) -> LauncherItem {
        LauncherItem(
            id: "quicklink:\(link.id):\(url.absoluteString)", title: title, subtitle: url.host() ?? url.path,
            icon: .symbol("link", .blue), accessory: .text(link.keyword),
            section: .quicklinks, score: score, highlight: highlight,
            primary: LauncherAction(title: L("launcher.action.open"), symbol: "safari") { [weak self] in
                self?.open(url, with: link.appBundleID)
            },
            actions: [
                LauncherAction(title: L("launcher.action.copyURL"), symbol: "doc.on.doc", shortcut: .command("c")) { Pasteboard.copy(url.absoluteString) },
                LauncherAction(title: L("launcher.action.edit"), symbol: "pencil", shortcut: .command("e")) {
                    KeystivoRuntime.shared.windowsUI.showSettings(section: .launcher)
                },
            ],
            usageKey: "quicklink:\(link.id)"
        )
    }

    private func open(_ url: URL, with bundleID: String?) {
        if let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Schedule

    /// Today's and tomorrow's events; meetings can be joined with ↩.
    func scheduleItems(_ text: String) -> [LauncherItem] {
        let service = CalendarService.shared
        guard service.hasAccess else {
            return [LauncherItem(
                id: "schedule:access", title: L(service.accessDenied ? "schedule.accessDenied" : "schedule.allowAccess"),
                subtitle: L("schedule.accessHelp"), icon: .symbol("calendar.badge.exclamationmark", .red), section: .results,
                primary: LauncherAction(title: L("permissions.grant"), symbol: "lock.open", dismisses: service.accessDenied) { [weak self] in
                    if service.accessDenied {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    } else {
                        _ = await service.requestAccess()
                        self?.refresh()
                    }
                }
            )]
        }
        let calendar = Calendar.current
        let locale = Localizer.shared.locale
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        return service.upcoming(days: 2).enumerated().compactMap { index, event in
            var score = Double(10_000 - index)
            var highlight: [Int] = []
            if !text.isEmpty {
                guard let match = FuzzyMatcher.bestMatch(text, title: event.title, alternates: [event.calendarName, event.location ?? ""]) else { return nil }
                score = match.score
                highlight = match.matchedOffsets
            }
            let day = calendar.isDateInToday(event.start) ? L("schedule.today")
                : calendar.isDateInTomorrow(event.start) ? L("schedule.tomorrow")
                : event.start.formatted(Date.FormatStyle(locale: locale).weekday(.wide))
            let when = event.isAllDay ? L("schedule.allDay") : "\(event.start.formatted(timeStyle)) – \(event.end.formatted(timeStyle))"
            let status = event.isHappening() && !event.isAllDay ? " · " + L("schedule.now") : ""
            var actions = [
                LauncherAction(title: L("schedule.openInCalendar"), symbol: "calendar", shortcut: .commandReturn) { service.open(event) },
            ]
            if let link = event.meetingURL {
                actions.append(LauncherAction(title: L("schedule.copyLink"), symbol: "doc.on.doc", shortcut: .command("c")) { Pasteboard.copy(link.absoluteString) })
            }
            return LauncherItem(
                id: "event:\(event.id):\(event.start.timeIntervalSince1970)", title: event.title,
                subtitle: "\(day) · \(when)\(status) · \(event.calendarName)",
                icon: .color(event.colorHex), accessory: event.meetingURL == nil ? nil : .text(L("schedule.join")),
                section: .results, score: score, highlight: highlight,
                primary: event.meetingURL.map { link in
                    LauncherAction(title: L("schedule.join"), symbol: "video") { NSWorkspace.shared.open(link) }
                } ?? LauncherAction(title: L("schedule.openInCalendar"), symbol: "calendar") { service.open(event) },
                actions: actions,
                preview: .text([event.title, "\(day) \(when)", event.location, event.meetingURL?.absoluteString].compactMap { $0 }.joined(separator: "\n"))
            )
        }
    }

    // MARK: Screenshot history

    func captureItems(_ text: String) -> [LauncherItem] {
        let locale = Localizer.shared.locale
        return CaptureHistory.shared.entries.enumerated().compactMap { index, entry in
            let title = entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
            if !text.isEmpty, FuzzyMatcher.bestMatch(text, title: title) == nil { return nil }
            let image = { NSImage(contentsOf: entry.url) }
            return LauncherItem(
                id: "capture:\(entry.url.lastPathComponent)", title: title,
                subtitle: entry.date.formatted(.relative(presentation: .named).locale(locale)),
                icon: CaptureThumbnails.thumbnail(for: entry.url).map(LauncherItem.Icon.image) ?? .symbol("photo", .purple),
                section: .results, score: Double(10_000 - index),
                primary: LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc") {
                    guard let image = image() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                    KeystivoRuntime.shared.hud.show(symbol: "doc.on.doc", text: L("capture.copiedImage"))
                },
                actions: [
                    LauncherAction(title: L("launcher.action.paste"), symbol: "doc.on.clipboard", shortcut: .commandReturn) {
                        guard let image = image() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                        try? await Task.sleep(for: .milliseconds(120))
                        SyntheticInput.paste()
                    },
                    LauncherAction(title: L("quickAccess.annotate"), symbol: "pencil.tip.crop.circle", shortcut: .command("e")) {
                        if let image = image() { KeystivoRuntime.shared.annotationEditor.open(image) }
                    },
                    LauncherAction(title: L("quickAccess.pin"), symbol: "pin", shortcut: .command("p")) {
                        if let image = image() { KeystivoRuntime.shared.screenTools.pin(image) }
                    },
                    LauncherAction(title: L("launcher.action.revealInFinder"), symbol: "folder", shortcut: .command("r")) {
                        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                    },
                    LauncherAction(title: L("launcher.action.delete"), symbol: "trash", shortcut: .commandDelete, dismisses: false, isDestructive: true) { [weak self] in
                        CaptureHistory.shared.remove(entry)
                        self?.removeItems { $0.id == "capture:\(entry.url.lastPathComponent)" }
                    },
                ],
                preview: (try? Data(contentsOf: entry.url)).map(LauncherItem.Preview.image)
            )
        }
    }

    // MARK: Aliases

    /// Items whose alias the query is ("kod" → Visual Studio Code); exact aliases rank first.
    func aliasItems(_ text: String) -> [LauncherItem] {
        let query = text.lowercased()
        guard !query.isEmpty else { return [] }
        return runtime.config.launcher.aliases.compactMap { key, alias in
            let alias = alias.lowercased()
            let score: Double
            if alias == query { score = 30_000 } else if query.count >= 2, alias.hasPrefix(query) { score = 12_000 } else { return nil }
            return item(forKey: key, score: score)
        }
    }

    /// Rebuilds a launcher item from its usage key.
    private func item(forKey key: String, score: Double) -> LauncherItem? {
        if key.hasPrefix("action:"), let descriptor = ActionRegistry.shared.descriptor(String(key.dropFirst(7))) {
            return commandItem(descriptor, score: score, highlight: [])
        }
        if key.hasPrefix("workflow:"), let workflow = runtime.config.automation.workflows.first(where: { "workflow:\($0.id)" == key }) {
            return workflowItem(workflow, score: score, highlight: [])
        }
        if key.hasPrefix("quicklink:"), let link = runtime.config.launcher.quicklinks.first(where: { "quicklink:\($0.id)" == key }),
           let url = link.resolvedURL(query: "", clipboard: nil) {
            var item = quicklinkItems(link.keyword).first ?? LauncherItem(
                id: key, title: link.name, icon: .symbol("link", .blue), section: .quicklinks,
                primary: LauncherAction(title: L("launcher.action.open"), symbol: "safari") { NSWorkspace.shared.open(url) })
            item.score = score
            return item
        }
        if let app = AppCatalog.shared.apps.first(where: { ($0.bundleID ?? $0.path) == key }) {
            return appItem(app, score: score, highlight: [])
        }
        return nil
    }

    /// "Set Alias…" for any item that can have one.
    func aliasAction(for item: LauncherItem) -> LauncherAction? {
        guard let key = item.usageKey, !key.hasPrefix("emoji:") else { return nil }
        let title = item.title
        return LauncherAction(title: L("launcher.action.setAlias"), symbol: "character.textbox", shortcut: KeyCombo(keyCode: KeyCodes.letterKeyCodes["a"] ?? 0, modifiers: [.command, .option])) { [weak self] in
            guard let self else { return }
            let current = runtime.config.launcher.aliases[key] ?? ""
            guard let alias = AutomationSources.askForInput(prompt: L("launcher.aliasPrompt", title), title: L("launcher.action.setAlias"), initial: current) else { return }
            let trimmed = alias.trimmingCharacters(in: .whitespaces)
            runtime.config.launcher.aliases[key] = trimmed.isEmpty ? nil : trimmed
            runtime.hud.show(symbol: "character.textbox", text: trimmed.isEmpty ? L("launcher.aliasRemoved") : L("launcher.aliasSet", trimmed, title))
        }
    }

    // MARK: Currency & world clock

    func worldItems(_ text: String) -> [LauncherItem] {
        currencyItems(text) + timeZoneItems(text)
    }

    private func currencyItems(_ text: String) -> [LauncherItem] {
        guard runtime.config.launcher.convertsCurrency, text.contains(where: \.isNumber) else { return [] }
        let table = exchangeRates
        guard let request = CurrencyConverter.parse(text, known: table?.codes ?? Self.commonCurrencies) else { return [] }
        guard let table else {
            loadExchangeRates()
            return [LauncherItem(
                id: "currency:loading", title: L("currency.loading"), subtitle: L("currency.source"), icon: .symbol("dollarsign.arrow.circlepath", .green),
                section: .calculator, score: 9_000, primary: LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc", dismisses: false) {}
            )]
        }
        if Date.now.timeIntervalSince(table.fetchedAt) > 12 * 3600 { loadExchangeRates() }
        let local = Localizer.shared.locale.currency?.identifier ?? Locale.current.currency?.identifier ?? "USD"
        let targets: [String] = if let to = request.to { [to] } else if request.from != local { [local] } else { ["USD", "EUR"].filter { $0 != request.from } }
        return targets.compactMap { target in
            guard let value = table.convert(request.amount, from: request.from, to: target) else { return nil }
            let style = FloatingPointFormatStyle<Double>.Currency(code: target, locale: Localizer.shared.locale)
            let result = value.formatted(style)
            let source = request.amount.formatted(FloatingPointFormatStyle<Double>.Currency(code: request.from, locale: Localizer.shared.locale))
            let raw = String(format: "%.2f", value)
            return LauncherItem(
                id: "currency:\(target)", title: result, subtitle: "\(source) · " + L("currency.rateDate", Self.rateDate(table.date)),
                icon: .symbol("dollarsign.arrow.circlepath", .green), accessory: .text(L("launcher.copy")),
                section: .calculator, score: 10_000,
                primary: LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc") { Pasteboard.copy(raw) },
                actions: [
                    LauncherAction(title: L("launcher.action.paste"), symbol: "doc.on.clipboard", shortcut: .commandReturn) { await Pasteboard.paste(raw) },
                    LauncherAction(title: L("currency.copyFormatted"), symbol: "textformat", shortcut: .command("c", shift: true)) { Pasteboard.copy(result) },
                ]
            )
        }
    }

    /// "2026-10-09" in the user's date style.
    static func rateDate(_ iso: String) -> String {
        guard let date = try? Date(iso + "T12:00:00Z", strategy: .iso8601) else { return iso }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Localizer.shared.locale))
    }

    static let commonCurrencies: Set<String> = ["USD", "EUR", "TRY", "GBP", "JPY", "CNY", "CHF", "KRW", "INR", "BRL", "CAD", "AUD"]

    private func loadExchangeRates() {
        guard !isLoadingRates else { return }
        isLoadingRates = true
        Task {
            let table = await ExchangeRates.shared.current()
            isLoadingRates = false
            if let table {
                exchangeRates = table
                refresh()
            }
        }
    }

    private func timeZoneItems(_ text: String) -> [LauncherItem] {
        guard let result = TimeZoneConverter.resolve(text) else { return [] }
        let locale = Localizer.shared.locale
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = result.timeZone
        var dayStyle = Date.FormatStyle(locale: locale).weekday(.wide)
        dayStyle.timeZone = result.timeZone
        let time = result.date.formatted(style)
        let offset = result.timeZone.secondsFromGMT(for: result.date) - TimeZone.current.secondsFromGMT(for: result.date)
        let offsetText = offset == 0 ? L("worldClock.sameTime") : L("worldClock.offset", (offset >= 0 ? "+" : "−") + Self.hours(abs(offset)))
        var subtitle = "\(result.place) · \(result.date.formatted(dayStyle)) · \(offsetText)"
        if let sourcePlace = result.sourcePlace, let sourceZone = result.sourceTimeZone {
            var sourceStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
            sourceStyle.timeZone = sourceZone
            subtitle = "\(sourcePlace) \(result.date.formatted(sourceStyle)) → " + subtitle
        }
        return [LauncherItem(
            id: "worldclock:\(result.timeZone.identifier)", title: time, subtitle: subtitle,
            icon: .symbol("globe.europe.africa", .teal), accessory: .text(L("launcher.copy")),
            section: .calculator, score: 10_000,
            primary: LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc") { Pasteboard.copy(time) },
            actions: [
                LauncherAction(title: L("launcher.action.paste"), symbol: "doc.on.clipboard", shortcut: .commandReturn) { await Pasteboard.paste(time) },
            ]
        )]
    }

    private static func hours(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours)" : String(format: "%d:%02d", hours, minutes)
    }

    // MARK: Dictionary

    /// "Define <word>" fallback using the dictionaries enabled in Dictionary.app.
    func dictionaryItem(_ text: String) -> LauncherItem? {
        let words = text.split(separator: " ")
        guard (1...3).contains(words.count), text.count <= 40, !text.contains(where: \.isNumber) else { return nil }
        return LauncherItem(
            id: "fallback:define", title: L("dictionary.define", text), icon: .symbol("character.book.closed", .brown),
            section: .fallback, score: 0.85,
            primary: LauncherAction(title: L("dictionary.show"), symbol: "book", dismisses: false) { [weak self] in
                self?.showDefinition(of: text)
            },
            actions: [
                LauncherAction(title: L("dictionary.openApp"), symbol: "character.book.closed", shortcut: .commandReturn) {
                    if let url = URL(string: "dict://" + (text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text)) {
                        NSWorkspace.shared.open(url)
                    }
                },
            ]
        )
    }

    func showDefinition(of text: String) {
        let range = CFRange(location: 0, length: (text as NSString).length)
        let definition = DCSCopyTextDefinition(nil, text as CFString, range)?.takeRetainedValue() as String?
        showPluginOutput(.text(definition ?? L("dictionary.notFound", text)), title: text)
    }

    // MARK: Emoji & symbols

    func emojiItems(_ text: String) -> [LauncherItem] {
        let language = Localizer.shared.languageCode
        let usage = runtime.config.usage
        var matches = EmojiCatalog.search(text, language: language)
        if text.isEmpty {
            // Recently used first.
            let recent = matches.filter { usage["emoji:\($0.entry.glyph)"] != nil }
                .sorted { (usage["emoji:\($0.entry.glyph)"]?.boost() ?? 0) > (usage["emoji:\($1.entry.glyph)"]?.boost() ?? 0) }
            let recentGlyphs = Set(recent.map(\.entry.glyph))
            matches = Array(recent.prefix(24)) + matches.filter { !recentGlyphs.contains($0.entry.glyph) }
        }
        return matches.prefix(400).enumerated().map { index, pair in
            let entry = pair.entry
            return LauncherItem(
                id: "emoji:\(entry.glyph)", title: entry.name.prefix(1).uppercased() + entry.name.dropFirst(),
                subtitle: entry.englishName == entry.name ? nil : entry.englishName,
                icon: .glyph(entry.glyph), accessory: .text(entry.isSymbol ? L("emoji.symbol") : ""),
                section: .results, score: (pair.match?.score ?? 0) + Double(-index) * 0.0001, highlight: pair.match?.matchedOffsets ?? [],
                primary: LauncherAction(title: L("launcher.action.paste"), symbol: "doc.on.clipboard") {
                    await Pasteboard.paste(entry.glyph)
                },
                actions: [
                    LauncherAction(title: L("launcher.action.copy"), symbol: "doc.on.doc", shortcut: .command("c")) { Pasteboard.copy(entry.glyph) },
                ],
                usageKey: "emoji:\(entry.glyph)"
            )
        }
    }

    // MARK: Menu items

    /// Starts reading the frontmost app's menus (called when the mode opens).
    func loadMenuItems() {
        menuEntries = []
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else {
            menuTargetName = nil
            return
        }
        menuTargetName = app.localizedName
        menuTargetPID = app.processIdentifier
        isLoadingMenus = true
        let pid = app.processIdentifier
        Task {
            let entries = await Task.detached(priority: .userInitiated) { MenuItemCollector.items(pid: pid) }.value
            guard mode == .menuItems, menuTargetPID == pid else { return }
            menuEntries = entries
            isLoadingMenus = false
            refresh()
        }
    }

    func menuItemItems(_ text: String) -> [LauncherItem] {
        let appName = menuTargetName ?? ""
        return menuEntries.enumerated().compactMap { index, entry in
            let location = entry.path.joined(separator: " › ")
            var score = Double(10_000 - index)
            var highlight: [Int] = []
            if !text.isEmpty {
                guard let match = FuzzyMatcher.bestMatch(text, title: entry.title, alternates: [location + " " + entry.title]) else { return nil }
                score = match.score + (entry.isEnabled ? 0 : -50)
                highlight = match.matchedOffsets
            }
            let combo = Self.combo(for: entry)
            return LauncherItem(
                id: "menu:\(entry.id)", title: (entry.isChecked ? "✓ " : "") + entry.title, subtitle: "\(appName) · \(location)",
                icon: .symbol(entry.isEnabled ? "filemenu.and.selection" : "nosign", entry.isEnabled ? .indigo : .gray),
                accessory: combo.map { .shortcut($0) } ?? entry.keyCharacter.map { .text(Self.modifierSymbols(entry.modifiers) + $0.uppercased()) },
                section: .results, score: score, highlight: highlight.map { $0 + (entry.isChecked ? 2 : 0) },
                primary: LauncherAction(title: L("menuItems.run"), symbol: "play") { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    if !entry.perform() { self?.runtime.hud.show(symbol: "exclamationmark.triangle", text: L("menuItems.failed")) }
                }
            )
        }
    }

    private static func combo(for entry: MenuItemEntry) -> KeyCombo? {
        let modifiers = KeyModifiers(NSEvent.ModifierFlags(rawValue: entry.modifiers))
        if let keyCode = entry.keyCode { return KeyCombo(keyCode: keyCode, modifiers: modifiers) }
        if let character = entry.keyCharacter?.lowercased().first, let code = KeyCodes.letterKeyCodes[character] {
            return KeyCombo(keyCode: code, modifiers: modifiers)
        }
        return nil
    }

    private static func modifierSymbols(_ raw: NSEvent.ModifierFlags.RawValue) -> String {
        KeyModifiers(NSEvent.ModifierFlags(rawValue: raw)).symbols
    }

    // MARK: Processes

    /// Samples CPU twice (CPU needs a baseline) and keeps refreshing while the mode is open.
    func startProcessSampling() {
        processTask?.cancel()
        let sampler = ProcessSampler()
        processTask = Task {
            var first = true
            while !Task.isCancelled, mode == .processes {
                let apps = Dictionary(NSWorkspace.shared.runningApplications.compactMap { app -> (pid_t, (name: String, bundleID: String?))? in
                    guard let name = app.localizedName else { return nil }
                    return (app.processIdentifier, (name, app.bundleIdentifier))
                }, uniquingKeysWith: { first, _ in first })
                let rows = await Task.detached(priority: .utility) { sampler.sample(apps: apps) }.value
                if !first {
                    processRows = rows.sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
                    refresh()
                }
                try? await Task.sleep(for: .milliseconds(first ? 600 : 2000))
                first = false
            }
        }
    }

    func processItems(_ text: String) -> [LauncherItem] {
        processRows.enumerated().compactMap { index, row in
            var score = Double(10_000 - index)
            var highlight: [Int] = []
            if !text.isEmpty {
                guard let match = FuzzyMatcher.bestMatch(text, title: row.name, alternates: [row.bundleID ?? "", String(row.id)]) else { return nil }
                score = match.score
                highlight = match.matchedOffsets
            }
            let memory = ByteCountFormatter.string(fromByteCount: Int64(row.memory), countStyle: .memory)
            let cpu = row.cpu.formatted(.number.precision(.fractionLength(1)).locale(Localizer.shared.locale)) + "%"
            let pid = row.id
            return LauncherItem(
                id: "process:\(pid)", title: row.name, subtitle: L("processes.detail", cpu, memory, String(pid)),
                icon: row.bundleID != nil ? .app(bundleID: row.bundleID, path: nil) : .symbol("gearshape.2", .gray),
                accessory: .text(cpu), section: .results, score: score, highlight: highlight,
                primary: LauncherAction(title: L("processes.quit"), symbol: "xmark.circle", dismisses: false) { [weak self] in
                    self?.signal(pid, force: false, name: row.name)
                },
                actions: [
                    LauncherAction(title: L("processes.forceQuit"), symbol: "exclamationmark.octagon", shortcut: .commandDelete, dismisses: false, isDestructive: true) { [weak self] in
                        self?.signal(pid, force: true, name: row.name)
                    },
                    LauncherAction(title: L("processes.copyPID"), symbol: "number", shortcut: .command("c")) { Pasteboard.copy(String(pid)) },
                ],
                requiresConfirmation: false
            )
        }
    }

    private func signal(_ pid: pid_t, force: Bool, name: String) {
        let succeeded: Bool
        if let app = NSRunningApplication(processIdentifier: pid) {
            succeeded = force ? app.forceTerminate() : app.terminate()
        } else {
            succeeded = kill(pid, force ? SIGKILL : SIGTERM) == 0
        }
        if succeeded {
            removeItems { $0.id == "process:\(pid)" }
            processRows.removeAll { $0.id == pid }
            showToast(L(force ? "processes.killed" : "processes.quitting", name))
        } else {
            showToast(L("processes.failed", name))
        }
    }
}


/// Thumbnails for screenshot history rows (decoded once per file).
enum CaptureThumbnails {
    private static var cache: [URL: NSImage] = [:]

    static func thumbnail(for url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        if cache.count > 100 { cache.removeAll() }
        cache[url] = image
        return image
    }
}
