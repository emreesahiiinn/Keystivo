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
import UniformTypeIdentifiers

// MARK: - Launcher

struct LauncherPage: View {
    @Bindable var runtime: KeystivoRuntime

    static let searchEngines: [(String, String)] = [
        ("DuckDuckGo", "https://duckduckgo.com/?q=%@"),
        ("Google", "https://www.google.com/search?q=%@"),
        ("Bing", "https://www.bing.com/search?q=%@"),
        ("Kagi", "https://kagi.com/search?q=%@"),
        ("Ecosia", "https://www.ecosia.org/search?q=%@"),
        ("Yandex", "https://yandex.com/search/?text=%@"),
        ("Baidu", "https://www.baidu.com/s?wd=%@"),
    ]

    var body: some View {
        Form {
            PageHeader(symbol: "magnifyingglass", color: .blue, titleKey: "settings.page.launcher", subtitleKey: "launcherSettings.subtitle")
            Section(L("launcherSettings.shortcuts")) {
                LabeledContent(L("action.launcher.show")) { ActionShortcutField(runtime: runtime, actionID: "launcher.show") }
                LabeledContent(L("action.launcher.files")) { ActionShortcutField(runtime: runtime, actionID: "launcher.files") }
                LabeledContent(L("action.launcher.windows")) { ActionShortcutField(runtime: runtime, actionID: "launcher.windows") }
                LabeledContent(L("action.launcher.quickActions")) { ActionShortcutField(runtime: runtime, actionID: "launcher.quickActions") }
                LabeledContent(L("action.launcher.emoji")) { ActionShortcutField(runtime: runtime, actionID: "launcher.emoji") }
                LabeledContent(L("action.launcher.menuItems")) { ActionShortcutField(runtime: runtime, actionID: "launcher.menuItems") }
                LabeledContent(L("action.launcher.processes")) { ActionShortcutField(runtime: runtime, actionID: "launcher.processes") }
            }
            Section(L("launcherSettings.results")) {
                Toggle(L("launcherSettings.calculator"), isOn: $runtime.config.launcher.showsCalculator)
                Toggle(L("launcherSettings.currency"), isOn: $runtime.config.launcher.convertsCurrency)
                Toggle(L("launcherSettings.windows"), isOn: $runtime.config.launcher.searchesWindows)
                Toggle(L("launcherSettings.files"), isOn: $runtime.config.launcher.searchesFiles)
                Toggle(L("launcherSettings.recent"), isOn: $runtime.config.launcher.showsRecent)
            }
            Section(L("launcherSettings.behavior")) {
                Picker(L("launcherSettings.position"), selection: $runtime.config.launcher.position) {
                    ForEach(LauncherPosition.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                Toggle(L("launcherSettings.clearQuery"), isOn: $runtime.config.launcher.clearsQueryOnOpen)
                Picker(L("launcherSettings.webSearch"), selection: $runtime.config.launcher.webSearchTemplate) {
                    ForEach(Self.searchEngines, id: \.1) { Text($0.0).tag($0.1) }
                    if !Self.searchEngines.contains(where: { $0.1 == runtime.config.launcher.webSearchTemplate }) {
                        Text(L("launcherSettings.custom")).tag(runtime.config.launcher.webSearchTemplate)
                    }
                }
                TextField(L("launcherSettings.customTemplate"), text: $runtime.config.launcher.webSearchTemplate)
                    .font(.system(.callout, design: .monospaced))
            }
            Section {
                QuicklinkList(links: $runtime.config.launcher.quicklinks)
            } header: {
                Text(L("quicklinks.title"))
            } footer: {
                Text(L("quicklinks.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(L("launcherSettings.indexedApps"), value: "\(AppCatalog.shared.apps.count)")
                HStack {
                    Button(L("launcherSettings.rescan")) { AppCatalog.shared.rescan() }
                    Button(L("launcherSettings.resetRanking"), role: .destructive) { runtime.config.usage = [:] }
                }
            } footer: {
                Text(L("launcherSettings.tips")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Editable list of quicklinks: name, keyword and URL template per row.
private struct QuicklinkList: View {
    @Binding var links: [Quicklink]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("quicklinks.name")).frame(width: 150, alignment: .leading)
                Text(L("quicklinks.keyword")).frame(width: 70, alignment: .leading)
                Text(L("quicklinks.url"))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach($links) { $link in
                HStack(spacing: 8) {
                    TextField("", text: $link.name).frame(width: 150)
                    TextField("", text: $link.keyword).frame(width: 70)
                    TextField("https://…{query}", text: $link.url)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(link.resolvedURL(query: "test") == nil ? Color.red : Color.primary)
                    Button(role: .destructive) {
                        links.removeAll { $0.id == link.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            HStack {
                Button {
                    links.append(Quicklink(name: L("quicklinks.newName"), keyword: "", url: "https://"))
                } label: {
                    Label(L("quicklinks.add"), systemImage: "plus")
                }
                Spacer()
                Button(L("quicklinks.restoreDefaults")) {
                    let existing = Set(links.map { $0.url })
                    links += Quicklink.defaults.filter { !existing.contains($0.url) }
                }
                .disabled(Quicklink.defaults.allSatisfy { link in links.contains { $0.url == link.url } })
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }
}

// MARK: - Clipboard

struct ClipboardPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var count = 0
    @State private var confirmClear = false

    var body: some View {
        Form {
            PageHeader(symbol: "clipboard.fill", color: .orange, titleKey: "settings.page.clipboard", subtitleKey: "clipboardSettings.subtitle")
            Section {
                Toggle(L("clipboardSettings.enabled"), isOn: $runtime.config.clipboard.isEnabled)
                LabeledContent(L("action.clipboard.history")) { ActionShortcutField(runtime: runtime, actionID: "clipboard.history") }
                Toggle(L("clipboardSettings.pastesDirectly"), isOn: $runtime.config.clipboard.pastesDirectly)
                Toggle(L("clipboardSettings.images"), isOn: $runtime.config.clipboard.capturesImages)
                Toggle(L("clipboardSettings.files"), isOn: $runtime.config.clipboard.capturesFiles)
            }
            Section(L("clipboardSettings.retention")) {
                Stepper(L("clipboardSettings.maxItems", runtime.config.clipboard.maxItems), value: $runtime.config.clipboard.maxItems, in: 50...5000, step: 50)
                Picker(L("clipboardSettings.keepFor"), selection: $runtime.config.clipboard.retentionDays) {
                    Text(L("clipboardSettings.days", 1)).tag(Optional(1))
                    Text(L("clipboardSettings.days", 7)).tag(Optional(7))
                    Text(L("clipboardSettings.days", 30)).tag(Optional(30))
                    Text(L("clipboardSettings.days", 90)).tag(Optional(90))
                    Text(L("clipboardSettings.forever")).tag(Int?.none)
                }
                LabeledContent(L("clipboardSettings.stored"), value: "\(count)")
            }
            Section {
                Toggle(L("clipboardSettings.memoryOnly"), isOn: $runtime.config.clipboard.memoryOnly)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("clipboardSettings.excluded"))
                    AppListEditor(bundleIDs: $runtime.config.clipboard.excludedBundleIDs)
                }
                if let note = pasteboardPrivacyNote {
                    Label(note, systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
                }
                Button(L("action.clipboard.clear"), role: .destructive) { confirmClear = true }
            } header: {
                Text(L("clipboardSettings.privacy"))
            } footer: {
                Text(L("clipboardSettings.privacyFooter")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: ClipboardMonitor.shared.revision) {
            count = (try? await ClipboardMonitor.shared.store?.count()) ?? 0
        }
        .confirmationDialog(L("action.clipboard.clear"), isPresented: $confirmClear) {
            Button(L("clipboardSettings.clearKeepPinned"), role: .destructive) { Task { await ClipboardMonitor.shared.clearHistory(keepPinned: true) } }
            Button(L("clipboardSettings.clearAll"), role: .destructive) { Task { await ClipboardMonitor.shared.clearHistory(keepPinned: false) } }
        }
    }

    private var pasteboardPrivacyNote: String? {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysDeny: return L("clipboardSettings.accessDenied")
            case .ask: return L("clipboardSettings.accessAsk")
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Snippets

struct SnippetsPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var selection: UUID?
    @State private var filter = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField(L("snippetsSettings.filter"), text: $filter).textFieldStyle(.roundedBorder).padding(8)
                List(selection: $selection) {
                    ForEach(groupedCollections, id: \.self) { collection in
                        Section(collection.isEmpty ? L("snippetsSettings.uncategorized") : collection) {
                            ForEach(filtered.filter { $0.collection == collection }) { snippet in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(snippet.name)
                                    if !snippet.keyword.isEmpty {
                                        Text(snippet.keyword).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                .opacity(snippet.isEnabled ? 1 : 0.5)
                                .tag(snippet.id)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Button {
                        let snippet = Snippet(name: L("snippetsSettings.new"), keyword: "", content: "")
                        runtime.config.snippets.snippets.append(snippet)
                        selection = snippet.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        runtime.config.snippets.snippets.removeAll { $0.id == selection }
                        selection = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Button { importSnippets() } label: { Image(systemName: "square.and.arrow.down") }
                        .help(L("snippetsSettings.import"))
                    Spacer()
                    Toggle(L("snippetsSettings.expansion"), isOn: $runtime.config.snippets.expansionEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 220, maxWidth: 300)

            Group {
                if let index = runtime.config.snippets.snippets.firstIndex(where: { $0.id == selection }) {
                    SnippetEditor(snippet: $runtime.config.snippets.snippets[index], allKeywords: runtime.config.snippets.snippets.map(\.keyword))
                } else {
                    Form {
                        PageHeader(symbol: "text.badge.plus", color: .teal, titleKey: "settings.page.snippets", subtitleKey: "snippetsSettings.subtitle")
                        Section(L("snippetsSettings.excluded")) { AppListEditor(bundleIDs: $runtime.config.snippets.excludedApps) }
                        Section(L("snippetsSettings.placeholders")) { placeholderHelp }
                    }
                    .formStyle(.grouped)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filtered: [Snippet] {
        guard !filter.isEmpty else { return runtime.config.snippets.snippets }
        return runtime.config.snippets.snippets.filter { FuzzyMatcher.bestMatch(filter, title: $0.name, alternates: [$0.keyword, $0.content]) != nil }
    }

    private var groupedCollections: [String] {
        Array(Set(filtered.map(\.collection))).sorted()
    }

    /// Raycast (JSON), Espanso (YAML), TextExpander or any CSV export.
    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .yaml, .commaSeparatedText, .plainText]
        panel.message = L("snippetsSettings.importHelp")
        guard panel.runModal() == .OK else { return }
        var added = 0, skipped = 0
        var existing = Set(runtime.config.snippets.snippets.map { "\($0.keyword)\u{1F}\($0.content)" })
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url), let imported = try? SnippetImporter.parse(data, fileName: url.lastPathComponent) else {
                skipped += 1
                continue
            }
            for snippet in imported where existing.insert("\(snippet.keyword)\u{1F}\(snippet.content)").inserted {
                runtime.config.snippets.snippets.append(snippet)
                added += 1
            }
        }
        let alert = NSAlert()
        alert.messageText = L("snippetsSettings.imported", added)
        if skipped > 0 { alert.informativeText = L("snippetsSettings.importSkipped", skipped) }
        alert.runModal()
    }

    private var placeholderHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(["{date}", "{time}", "{datetime}", "{date:yyyy-MM-dd}", "{clipboard}", "{uuid}", "{cursor}"], id: \.self) { token in
                HStack {
                    Text(token).font(.caption.monospaced())
                    Spacer()
                    Text(L("snippetsSettings.placeholder.\(token.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).components(separatedBy: ":").first ?? "")"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct SnippetEditor: View {
    @Binding var snippet: Snippet
    let allKeywords: [String]

    var body: some View {
        Form {
            Section {
                TextField(L("snippetsSettings.name"), text: $snippet.name)
                TextField(L("snippetsSettings.keyword"), text: $snippet.keyword, prompt: Text(";sig"))
                    .font(.system(.body, design: .monospaced))
                if !snippet.keyword.isEmpty, allKeywords.filter({ $0 == snippet.keyword }).count > 1 {
                    Label(L("snippetsSettings.duplicateKeyword"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                } else if !snippet.keyword.isEmpty, let longer = allKeywords.first(where: { $0 != snippet.keyword && $0.hasPrefix(snippet.keyword) }) {
                    // This keyword fires before the longer one can be finished.
                    Label(L("snippetsSettings.shadowsKeyword", longer), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                } else if !snippet.keyword.isEmpty, let shorter = allKeywords.first(where: { $0 != snippet.keyword && snippet.keyword.hasPrefix($0) }) {
                    Label(L("snippetsSettings.shadowedBy", shorter), systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                TextField(L("snippetsSettings.collection"), text: $snippet.collection)
                Toggle(L("snippetsSettings.enabled"), isOn: $snippet.isEnabled)
            }
            Section(L("snippetsSettings.content")) {
                TextEditor(text: $snippet.content)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
            }
            Section(L("snippetsSettings.preview")) {
                Text(SnippetRenderer.render(snippet.content, clipboard: NSPasteboard.general.string(forType: .string), locale: Localizer.shared.locale).text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Plugins

struct PluginsPage: View {
    let runtime: KeystivoRuntime
    @State private var installError: String?

    var body: some View {
        let manager = PluginManager.shared
        Form {
            PageHeader(symbol: "puzzlepiece.extension.fill", color: .cyan, titleKey: "settings.page.plugins", subtitleKey: "pluginsSettings.subtitle")
            Section {
                LabeledContent(L("pluginsSettings.folder")) {
                    Text(manager.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button(L("pluginsSettings.reveal")) { manager.revealInFinder() }
                    Button(L("pluginsSettings.reload")) { manager.reload() }
                    Button(L("pluginsSettings.installExample")) {
                        guard let url = PluginManager.bundledExampleURL else { return }
                        do { try manager.installExample(from: url) } catch { installError = error.localizedDescription }
                    }
                }
                if let installError { Text(installError).font(.caption).foregroundStyle(.red) }
            }
            if manager.plugins.isEmpty {
                Section { Text(L("pluginsSettings.empty")).foregroundStyle(.secondary) }
            }
            ForEach(manager.plugins) { plugin in
                Section {
                    PluginRow(plugin: plugin)
                }
            }
            if !manager.loadErrors.isEmpty {
                Section(L("pluginsSettings.errors")) {
                    ForEach(manager.loadErrors.sorted(by: { $0.key < $1.key }), id: \.key) { name, error in
                        VStack(alignment: .leading) {
                            Text(name).font(.callout.weight(.semibold))
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            Section(L("pluginsSettings.format")) {
                Text(L("pluginsSettings.formatBody")).font(.caption).foregroundStyle(.secondary)
                Text("""
                MyPlugin.keystivoplugin/
                  manifest.json   { "id", "name", "version", "commands": [ { "id", "title", "mode": "list|text|silent", "script" } ] }
                  script.sh       prints text, or {"items":[{"title","subtitle","icon","action":{"type":"copy|open|paste","value"}}]}
                """)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.reload() }
    }
}

private struct PluginRow: View {
    let plugin: LoadedPlugin

    var body: some View {
        let manager = PluginManager.shared
        let trusted = manager.isTrusted(plugin)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SymbolTile(symbol: plugin.manifest.icon ?? "puzzlepiece.extension", color: .cyan, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.manifest.localizedName(for: Localizer.shared.languageCode)).font(.headline)
                    Text("\(plugin.manifest.id) · v\(plugin.manifest.version)\(plugin.manifest.author.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if trusted {
                    Toggle(L("pluginsSettings.enabled"), isOn: Binding(get: { manager.isEnabled(plugin) }, set: { manager.setEnabled($0, for: plugin) }))
                        .toggleStyle(.switch)
                    Button(L("pluginsSettings.revoke")) { manager.revoke(plugin) }.buttonStyle(.borderless)
                } else {
                    Button(L("pluginsSettings.trust")) { manager.trust(plugin) }
                }
            }
            if let description = plugin.manifest.description { Text(description).font(.caption).foregroundStyle(.secondary) }
            if !trusted {
                Label(L("pluginsSettings.trustWarning"), systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
            }
            ForEach(plugin.manifest.commands) { command in
                HStack {
                    Image(systemName: command.icon ?? "chevron.right").frame(width: 16).foregroundStyle(.secondary)
                    Text(plugin.title(of: command, language: Localizer.shared.languageCode)).font(.callout)
                    Badge(text: command.mode.rawValue)
                    Spacer()
                    Text(command.script).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
