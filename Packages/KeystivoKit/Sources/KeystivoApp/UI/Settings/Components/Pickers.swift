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

/// Pick an installed application (search popover, or browse with an open panel).
struct AppPickerButton: View {
    @Binding var bundleID: String
    var placeholderKey = "picker.chooseApp"
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                if !bundleID.isEmpty {
                    AppIconView(bundleID: bundleID, size: 16)
                    Text(AppDisplayName.name(forBundleID: bundleID) ?? bundleID).lineLimit(1)
                } else {
                    Image(systemName: "app.dashed")
                    Text(L(placeholderKey)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AppPickerList { picked in
                bundleID = picked
                isPresented = false
            }
        }
    }
}

struct AppPickerList: View {
    let onPick: (String) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("picker.searchApps"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(results, id: \.path) { app in
                Button {
                    if let id = app.bundleID { onPick(id) }
                } label: {
                    HStack {
                        AppIconView(path: app.path, size: 20)
                        Text(app.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            Divider()
            HStack {
                Button(L("picker.browse")) { browse() }
                Spacer()
                if let front = NSWorkspace.shared.runningApplications.first(where: { $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier })?.bundleIdentifier {
                    Button(L("picker.frontmost")) { onPick(front) }
                }
            }
            .padding(8)
        }
        .frame(width: 320, height: 380)
        .onAppear { AppCatalog.shared.refreshIfNeeded() }
    }

    private var results: [AppRecord] {
        let apps = AppCatalog.shared.apps.filter { $0.bundleID != nil }
        guard !query.isEmpty else { return apps }
        return AppCatalog.shared.search(query, limit: 50).map(\.app)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier {
            onPick(id)
        }
    }
}

/// Editable list of apps (bundle IDs) with icons.
struct AppListEditor: View {
    @Binding var bundleIDs: [String]
    var emptyKey = "picker.noApps"
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bundleIDs.isEmpty {
                Text(L(emptyKey)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(bundleIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    AppIconView(bundleID: id, size: 18)
                    Text(AppDisplayName.name(forBundleID: id) ?? id).lineLimit(1)
                    Spacer()
                    Button {
                        bundleIDs.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("common.remove"))
                }
            }
            Button {
                isAdding = true
            } label: {
                Label(L("picker.addApp"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isAdding) {
                AppPickerList { id in
                    if !bundleIDs.contains(id) { bundleIDs.append(id) }
                    isAdding = false
                }
            }
        }
    }
}

/// Multi-select of user profiles (empty = all profiles).
struct ProfileScopePicker: View {
    @Binding var profileIDs: [UUID]
    let profiles: [UserProfile]

    var body: some View {
        Menu {
            Button {
                profileIDs = []
            } label: {
                if profileIDs.isEmpty {
                    Label(L("scope.allProfiles"), systemImage: "checkmark")
                } else {
                    Text(L("scope.allProfiles"))
                }
            }
            Divider()
            ForEach(profiles) { profile in
                Button {
                    if let index = profileIDs.firstIndex(of: profile.id) { profileIDs.remove(at: index) } else { profileIDs.append(profile.id) }
                } label: {
                    Label(profile.name, systemImage: profileIDs.contains(profile.id) ? "checkmark" : profile.symbolName)
                }
            }
        } label: {
            Text(summary).lineLimit(1)
        }
        .fixedSize()
    }

    private var summary: String {
        if profileIDs.isEmpty { return L("scope.allProfiles") }
        return profiles.filter { profileIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
    }
}

/// A small curated SF Symbol picker.
struct SymbolPicker: View {
    @Binding var symbol: String
    static let symbols = [
        "briefcase.fill", "house.fill", "person.fill", "moon.fill", "sun.max.fill", "leaf.fill", "bolt.fill", "star.fill",
        "heart.fill", "flame.fill", "gamecontroller.fill", "book.fill", "graduationcap.fill", "music.note", "film.fill",
        "paintbrush.fill", "hammer.fill", "chevron.left.forwardslash.chevron.right", "terminal.fill", "globe", "airplane",
        "cup.and.saucer.fill", "video.fill", "headphones", "display.2", "rectangle.3.group.fill", "square.stack.3d.up.fill",
        "bubble.left.and.bubble.right.fill", "envelope.fill", "cart.fill", "camera.fill", "sparkles",
    ]

    var body: some View {
        Menu {
            ForEach(Self.symbols, id: \.self) { name in
                Button { symbol = name } label: { Label(name, systemImage: name) }
            }
        } label: {
            Image(systemName: symbol)
        }
        .fixedSize()
    }
}

/// Colored dot picker for profiles.
struct ColorNamePicker: View {
    @Binding var colorName: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Theme.colorNames, id: \.self) { name in
                Circle()
                    .fill(Theme.color(named: name))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: colorName == name ? 2 : 0))
                    .onTapGesture { colorName = name }
                    .accessibilityLabel(name)
            }
        }
    }
}

/// Header + description used at the top of each settings page.
struct PageHeader: View {
    let symbol: String
    let color: Color
    let titleKey: String
    let subtitleKey: String

    var body: some View {
        HStack(spacing: 14) {
            SymbolTile(symbol: symbol, color: color, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(titleKey)).font(.title2.weight(.semibold))
                Text(L(subtitleKey)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
