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

/// "AppCleaner": choose an app, review everything that belongs to it, move it all to the Trash.
struct UninstallerView: View {
    @State private var query = ""
    @State private var selectedApp: AppRecord?
    @State private var items: [LeftoverItem] = []
    @State private var excluded = Set<String>()
    @State private var isScanning = false
    @State private var confirm = false
    @State private var message: String?
    @State private var isTargeted = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField(L("uninstall.search"), text: $query).textFieldStyle(.roundedBorder).padding(10)
                List(apps, id: \.path, selection: Binding(get: { selectedApp?.path }, set: { path in
                    selectedApp = AppCatalog.shared.apps.first { $0.path == path }
                })) { app in
                    HStack {
                        AppIconView(path: app.path, size: 22)
                        Text(app.name)
                    }
                    .tag(app.path)
                }
            }
            .frame(minWidth: 220, maxWidth: 280)

            VStack(alignment: .leading, spacing: 12) {
                if let app = selectedApp {
                    HStack(spacing: 12) {
                        AppIconView(path: app.path, size: 48)
                        VStack(alignment: .leading) {
                            Text(app.name).font(.title2.weight(.semibold))
                            Text(app.bundleID ?? app.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isScanning { ProgressView().controlSize(.small) }
                    }
                    if !AppUninstaller.isRemovable(app.url) {
                        Label(L("uninstall.protected"), systemImage: "lock.shield").foregroundStyle(.orange)
                    }
                    List {
                        ForEach(LeftoverItem.Category.allCases, id: \.self) { category in
                            LeftoverSection(category: category, items: items.filter { $0.category == category }, excluded: $excluded)
                        }
                    }
                    HStack {
                        Text(L("uninstall.total", ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file)))
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button(L("uninstall.button"), role: .destructive) { confirm = true }
                            .disabled(items.isEmpty || !AppUninstaller.isRemovable(app.url) || isScanning)
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    ContentUnavailableView {
                        Label(L("uninstall.title"), systemImage: "trash.square")
                    } description: {
                        Text(L("uninstall.intro"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5])).opacity(isTargeted ? 1 : 0))
                }
                if let message { Label(message, systemImage: "info.circle").font(.callout) }
            }
            .padding(18)
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension == "app" else { return }
                    Task { @MainActor in
                        selectedApp = AppCatalog.shared.apps.first { $0.path == url.path }
                            ?? AppRecord(path: url.path, name: url.deletingPathExtension().lastPathComponent, bundleID: Bundle(url: url)?.bundleIdentifier, aliases: [])
                    }
                }
                return true
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task(id: selectedApp?.path) { await scan() }
        .onAppear { AppCatalog.shared.refreshIfNeeded() }
        .confirmationDialog(L("uninstall.confirm", selectedApp?.name ?? ""), isPresented: $confirm) {
            Button(L("uninstall.button"), role: .destructive) { Task { await uninstall() } }
        } message: {
            Text(L("uninstall.confirmMessage", ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file)))
        }
    }

    private var apps: [AppRecord] {
        let all = AppCatalog.shared.apps.filter { !$0.path.hasPrefix("/System/") }
        guard !query.isEmpty else { return all }
        return AppCatalog.shared.search(query, limit: 60).map(\.app).filter { !$0.path.hasPrefix("/System/") }
    }

    private var selectedItems: [LeftoverItem] { items.filter { !excluded.contains($0.id) } }
    private var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    private func scan() async {
        guard let app = selectedApp else { return }
        message = nil
        excluded = []
        isScanning = true
        items = await AppUninstaller.scan(appURL: app.url)
        isScanning = false
    }

    private func uninstall() async {
        do {
            let freed = try await AppUninstaller.uninstall(selectedItems)
            message = L("uninstall.done", selectedApp?.name ?? "", ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))
            selectedApp = nil
            items = []
            AppCatalog.shared.rescan()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct LeftoverSection: View {
    let category: LeftoverItem.Category
    let items: [LeftoverItem]
    @Binding var excluded: Set<String>

    var body: some View {
        if !items.isEmpty {
            Section(L(category.titleKey)) {
                ForEach(items) { item in
                    LeftoverRow(item: item, isIncluded: Binding(
                        get: { !excluded.contains(item.id) },
                        set: { on in
                            if on { excluded.remove(item.id) } else { excluded.insert(item.id) }
                        }
                    ))
                }
            }
        }
    }
}

private struct LeftoverRow: View {
    let item: LeftoverItem
    @Binding var isIncluded: Bool

    var body: some View {
        HStack {
            Toggle("", isOn: $isIncluded)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(item.category == .application)
            Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button(L("launcher.action.revealInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }
}
