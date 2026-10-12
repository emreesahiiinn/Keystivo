import AppKit
import KeystivoCore
import KeystivoScreenSaver
import SwiftUI

struct ScreenSaversPage: View {
    @Bindable var runtime: KeystivoRuntime
    @State private var errorMessage: String?

    private var savers: ScreenSaverManager { runtime.screenSavers }

    var body: some View {
        Form {
            PageHeader(symbol: "sparkles.tv", color: .purple, titleKey: "settings.page.screenSavers", subtitleKey: "screenSavers.subtitle")
            Section {
                HStack(spacing: 10) {
                    statusLabel
                    Spacer()
                    switch savers.status {
                    case .notInstalled:
                        Button(L("screenSavers.install")) { install() }.buttonStyle(.borderedProminent)
                    case .outdated:
                        Button(L("screenSavers.update")) { install() }.buttonStyle(.borderedProminent)
                    case .installed:
                        Button(L("screenSavers.remove"), role: .destructive) {
                            do { try savers.uninstall() } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    Button(L("screenSavers.openSettings")) { ScreenSaverManager.openSystemSettings() }
                }
                .disabled(!savers.isAvailable)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                LabeledContent(L("action.screensaver.start")) { ActionShortcutField(runtime: runtime, actionID: "screensaver.start") }
            } footer: {
                Text(L("screenSavers.footer")).font(.caption).foregroundStyle(.secondary)
            }
            keystivoSaver
            Section(L("screenSavers.designs")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 16) {
                    ForEach(SaverStyle.allCases) { style in
                        SaverCard(style: style, onPreview: { savers.showPreview(style) }, onUse: { use(style) })
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
        .onAppear { savers.refresh() }
    }

    private var saver: Binding<KeystivoSaverSettings> { $runtime.config.tools.keystivoSaver }

    /// Keystivo runs the saver itself: the only way to see the desktop through it.
    private var keystivoSaver: some View {
        let settings = runtime.config.tools.keystivoSaver
        return Section {
            Toggle(L("screenSavers.keystivo.idle"), isOn: saver.startsWhenIdle)
            Picker(L("screenSavers.keystivo.after"), selection: saver.idleMinutes) {
                ForEach([1, 2, 3, 5, 10, 15, 30], id: \.self) { minutes in
                    Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide))).tag(minutes)
                }
            }
            .disabled(!settings.startsWhenIdle)
            Picker(L("screenSavers.keystivo.design"), selection: saver.style) {
                ForEach(SaverStyle.allCases) { Label(L($0.titleKey), systemImage: $0.symbol).tag($0) }
            }
            Picker(L("screenSavers.keystivo.backdrop"), selection: saver.backdrop) {
                ForEach(SaverBackdrop.allCases) { Text(L($0.titleKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!settings.style.supportsBackdrop)
            if !settings.style.supportsBackdrop {
                Text(L("screenSavers.keystivo.ownBackground")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                LabeledContent(L("action.screensaver.keystivo")) { ActionShortcutField(runtime: runtime, actionID: "screensaver.keystivo") }
                Button(L("screenSavers.preview")) { savers.showPreview(settings.style, backdrop: settings.backdrop) }
            }
        } header: {
            Text(L("screenSavers.keystivo.title"))
        } footer: {
            Text(L("screenSavers.keystivo.footer")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusLabel: some View {
        let (key, symbol, color): (String, String, Color) = switch savers.status {
        case .notInstalled: ("screenSavers.status.notInstalled", "circle.dashed", .secondary)
        case .outdated: ("screenSavers.status.outdated", "arrow.triangle.2.circlepath", .orange)
        case .installed: ("screenSavers.status.installed", "checkmark.circle.fill", .green)
        }
        return Label(L(key), systemImage: symbol).foregroundStyle(color)
    }

    private func use(_ style: SaverStyle) {
        Task {
            let selected = await savers.use(style)
            if selected {
                runtime.hud.show(symbol: "checkmark.circle.fill", text: L("screenSavers.selected", L(style.titleKey)))
            } else {
                errorMessage = L("screenSavers.selectFailed")
            }
        }
    }

    private func install() {
        do {
            let count = try savers.install()
            errorMessage = nil
            runtime.hud.show(symbol: "sparkles.tv", text: L("screenSavers.installedHUD", count))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SaverCard: View {
    let style: SaverStyle
    let onPreview: () -> Void
    let onUse: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if hovering {
                    // Live animation only for the card under the pointer.
                    SaverRootView(style: style, isPreview: true)
                } else {
                    // Others refresh once a second: correct clocks, little CPU.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        SaverRootView(style: style, isPreview: true, fixedDate: context.date)
                    }
                }
            }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(hovering ? 0.35 : 0.1), lineWidth: 1))
                .overlay {
                    if hovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(Circle().fill(.black.opacity(0.55)))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(hovering ? 1.02 : 1)
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 10 : 4, y: 3)
                .animation(.snappy(duration: 0.18), value: hovering)
                .contentShape(Rectangle())
                .onTapGesture(perform: onPreview)
                .help(L("screenSavers.preview"))
            HStack {
                Label(L(style.titleKey), systemImage: style.symbol)
                    .font(.callout.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(L("screenSavers.use"), action: onUse)
                    .controlSize(.small)
            }
        }
        .onHover { hovering = $0 }
    }
}
