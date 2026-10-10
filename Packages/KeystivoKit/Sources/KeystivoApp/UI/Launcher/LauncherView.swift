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
@preconcurrency import Translation

struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            footer
        }
        .keystivoPanelBackground()
        .overlay(GlowBorder())
        .popIn(token: model.focusToken)
        .overlay(alignment: .bottomTrailing) {
            if model.isActionPanelOpen, let item = model.selectedItem {
                ActionPanelView(item: item, selection: model.actionIndex) { action in
                    model.perform(action, of: item)
                }
                .padding(.trailing, 12)
                .padding(.bottom, 46)
                .transition(.scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: model.isActionPanelOpen)
        .onChange(of: model.focusToken, initial: true) { searchFocused = true }
        .translationTask(model.translationConfiguration) { session in
            do {
                let response = try await session.translate(model.translationText)
                model.translationFinished(.success(response.targetText))
            } catch {
                model.translationFinished(.failure(error))
            }
        }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            if let titleKey = model.mode.titleKey {
                Button {
                    model.open(mode: .root)
                } label: {
                    Label(L(titleKey), systemImage: model.mode.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help(L("launcher.backToSearch"))
            } else if case .pluginOutput(let title) = model.mode {
                Label(title, systemImage: model.mode.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.cyan.opacity(0.18)))
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(model.isLoading ? Color.accentColor : .secondary)
                    .symbolEffect(.pulse, isActive: model.isLoading)
                    .symbolEffect(.bounce, value: model.focusToken)
            }
            TextField(L(model.mode.placeholderKey), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .focused($searchFocused)
                .accessibilityLabel(L("launcher.accessibility.search"))
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let text = model.pluginText {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        } else if model.items.isEmpty {
            emptyState
        } else if showsPreview {
            HStack(spacing: 0) {
                ResultsList(model: model)
                    .frame(width: 330)
                Divider().opacity(0.5)
                PreviewPane(item: model.selectedItem)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ResultsList(model: model)
        }
    }

    private var showsPreview: Bool {
        switch model.mode {
        case .clipboard, .snippets, .textActions: true
        default: false
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.mode == .clipboard ? "clipboard" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L(model.query.isEmpty ? emptyKey : "launcher.empty.noResults"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyKey: String {
        switch model.mode {
        case .clipboard: "launcher.empty.clipboard"
        case .files: "launcher.empty.files"
        case .snippets: "launcher.empty.snippets"
        default: "launcher.empty.default"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Image(systemName: "command.square.fill")
                .foregroundStyle(Color.accentColor)
            if let toast = model.toast {
                Text(toast).font(.caption).foregroundStyle(.secondary)
            } else if let item = model.selectedItem, model.pendingConfirmationID == item.id {
                Text(L("launcher.confirm")).font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else {
                Text("Keystivo").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
            if let item = model.selectedItem {
                footerButton(item.primary.title, keys: ["↩"]) { model.performSelected() }
                Divider().frame(height: 14)
                footerButton(L("launcher.actions"), keys: ["⌘", "K"]) { model.toggleActionPanel() }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    private func footerButton(_ title: String, keys: [String], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.caption.weight(.medium))
                HStack(spacing: 2) {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .frame(minWidth: 16, minHeight: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Results

private struct ResultsList: View {
    @Bindable var model: LauncherModel
    @Namespace private var selectionNamespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.sections) { group in
                        if model.mode == .root || group.section == .recent {
                            Text(L(group.section.titleKey))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 10)
                                .padding(.bottom, 3)
                        }
                        ForEach(group.items) { item in
                            let index = model.items.firstIndex { $0.id == item.id } ?? 0
                            ResultRow(item: item, isSelected: index == model.selectedIndex, ordinal: index < 9 ? index + 1 : nil, namespace: selectionNamespace)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    model.selectedIndex = index
                                    model.performSelected()
                                }
                                .onTapGesture { model.selectedIndex = index }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .animation(.spring(response: 0.26, dampingFraction: 0.86), value: model.selectedIndex)
                .animation(.easeOut(duration: 0.15), value: model.items.map(\.id))
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedIndex) { _, index in
                guard model.items.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(model.items[index].id) }
            }
        }
    }
}

private struct ResultRow: View {
    let item: LauncherItem
    let isSelected: Bool
    let ordinal: Int?
    let namespace: Namespace.ID
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            LauncherIconView(icon: item.icon)
                .frame(width: 26, height: 26)
                .scaleEffect(isSelected ? 1.08 : 1)
                .shadow(color: isSelected ? Color.accentColor.opacity(0.35) : .clear, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            switch item.accessory {
            case .shortcut(let combo)?:
                KeyCapsView(combo: combo, compact: true)
            case .text(let text)?:
                Text(text).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            case nil:
                EmptyView()
            }
            if isSelected, let ordinal {
                Text("⌘\(ordinal)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, item.subtitle == nil ? 8 : 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.30), Color.accentColor.opacity(0.16)], startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.6))
                    .matchedGeometryEffect(id: "selection", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous).fill(Color.primary.opacity(0.05))
            }
        }
        .onHover { hovering = $0 }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var highlighted: AttributedString {
        var string = AttributedString(item.title)
        guard !item.highlight.isEmpty else { return string }
        let characters = Array(item.title)
        var index = string.startIndex
        for offset in 0..<characters.count {
            guard index < string.endIndex else { break }
            let next = string.characters.index(after: index)
            if item.highlight.contains(offset) {
                string[index..<next].inlinePresentationIntent = .stronglyEmphasized
                string[index..<next].foregroundColor = .accentColor
            }
            index = next
        }
        return string
    }
}

struct LauncherIconView: View {
    let icon: LauncherItem.Icon

    var body: some View {
        switch icon {
        case .app(let bundleID, let path):
            AppIconView(bundleID: bundleID, path: path, size: 26)
        case .symbol(let name, let color):
            SymbolTile(symbol: name, color: color, size: 24)
        case .file(let path):
            Image(nsImage: AppIconCache.shared.icon(forPath: path)).resizable().frame(width: 26, height: 26)
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 5))
        case .color(let hex):
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: hex) ?? .gray).frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
        }
    }
}

// MARK: - Preview

private struct PreviewPane: View {
    let item: LauncherItem?

    var body: some View {
        Group {
            switch item?.preview {
            case .text(let text)?:
                ScrollView {
                    Text(text)
                        .font(.system(.callout, design: looksLikeCode(text) ? .monospaced : .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            case .image(let data)?:
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(16)
                }
            case .clipboard(let entry)?:
                ClipboardPreview(entry: entry)
            case nil:
                Color.clear
            }
        }
    }

    private func looksLikeCode(_ text: String) -> Bool {
        text.contains("{") || text.contains(";\n") || text.contains("func ") || text.contains("=>")
    }
}

private struct ClipboardPreview: View {
    let entry: ClipboardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch entry.kind {
                case .image:
                    if let data = entry.data, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .color:
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: entry.text) ?? .gray).frame(height: 120)
                case .file:
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entry.filePaths, id: \.self) { path in
                            HStack {
                                Image(nsImage: AppIconCache.shared.icon(forPath: path)).resizable().frame(width: 32, height: 32)
                                Text(path).font(.caption).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                default:
                    ScrollView {
                        Text(entry.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 4) {
                metadata(L("clipboard.meta.type"), L(entry.kind.titleKey))
                if let source = entry.sourceBundleID.flatMap(AppDisplayName.name(forBundleID:)) {
                    metadata(L("clipboard.meta.source"), source)
                }
                metadata(L("clipboard.meta.copied"), entry.createdAt.formatted(.dateTime.locale(Localizer.shared.locale)))
                if entry.kind == .text || entry.kind == .richText {
                    metadata(L("clipboard.meta.characters"), "\(entry.text.count)")
                }
            }
            .padding(12)
        }
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1)
        }
        .font(.caption)
    }
}

// MARK: - Action panel (⌘K)

private struct ActionPanelView: View {
    let item: LauncherItem
    let selection: Int
    let perform: (LauncherAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(Array(item.allActions.enumerated()), id: \.element.id) { index, action in
                Button { perform(action) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol)
                            .frame(width: 18)
                            .foregroundStyle(action.isDestructive ? Color.red : Color.secondary)
                        Text(action.title)
                            .foregroundStyle(action.isDestructive ? Color.red : Color.primary)
                        Spacer(minLength: 16)
                        if index == 0 {
                            Text("↩").font(.caption).foregroundStyle(.tertiary)
                        } else if let shortcut = action.shortcut {
                            KeyCapsView(combo: shortcut, compact: true)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(index == selection ? Color.accentColor.opacity(0.22) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 300)
        .keystivoPanelBackground(cornerRadius: 12, material: .menu)
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255, blue: Double(number & 0xFF) / 255)
    }
}
