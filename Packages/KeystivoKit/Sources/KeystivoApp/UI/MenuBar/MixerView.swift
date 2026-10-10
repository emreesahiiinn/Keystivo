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

/// Quick sound mixer ("hızlı ses mikseri"): system output, input and per-app levels.
struct MixerView: View {
    let runtime: KeystivoRuntime
    var compact = false

    private var devices: AudioDeviceManager { .shared }
    private var apps: AppAudioController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            outputSection
            inputSection
            Divider()
            appsSection
        }
    }

    // MARK: Output / input

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L("audio.output"), systemImage: "speaker.wave.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                devicePicker(devices.outputDevices, selected: devices.defaultOutput?.uid) { uid in
                    try? devices.setDefaultOutput(uid: uid)
                }
            }
            HStack(spacing: 8) {
                Button { devices.toggleOutputMute() } label: {
                    Image(systemName: devices.outputMuted ? "speaker.slash.fill" : "speaker.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(L("action.audio.toggleMute"))
                Slider(value: Binding(get: { Double(devices.outputVolume) }, set: { devices.setOutputVolume(Float($0)) }), in: 0...1)
                    .controlSize(.small)
                Text("\(Int((devices.outputMuted ? 0 : devices.outputVolume) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private var inputSection: some View {
        HStack(spacing: 8) {
            Button { devices.toggleInputMute() } label: {
                Image(systemName: devices.inputMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(devices.inputMuted ? Color.red : Color.primary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(L("action.audio.toggleMic"))
            Text(L(devices.inputMuted ? "audio.mic.muted" : "audio.mic.live"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            devicePicker(devices.inputDevices, selected: devices.defaultInput?.uid) { uid in
                try? devices.setDefaultInput(uid: uid)
            }
        }
    }

    private func devicePicker(_ list: [AudioDevice], selected: String?, onSelect: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(list) { device in
                Button {
                    onSelect(device.uid)
                } label: {
                    if device.uid == selected {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Label(device.name, systemImage: device.symbolName)
                    }
                }
            }
        } label: {
            Text(list.first { $0.uid == selected }?.name ?? "—")
                .font(.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("mixer.apps")).font(.subheadline.weight(.semibold))
                Spacer()
                if !apps.settings.isEmpty {
                    Button(L("mixer.resetAll")) { apps.resetAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if !runtime.config.audio.appVolumeEnabled {
                Text(L("mixer.disabled")).font(.caption).foregroundStyle(.secondary)
            } else if apps.entries.isEmpty {
                Text(L("mixer.empty")).font(.caption).foregroundStyle(.secondary)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { _ in
                    VStack(spacing: 8) {
                        ForEach(apps.entries.prefix(compact ? 6 : 20)) { entry in
                            AppMixerRow(entry: entry)
                        }
                    }
                }
            }
            if let error = apps.lastError {
                Label(L("mixer.error"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
    }
}

private struct AppMixerRow: View {
    let entry: AppAudioEntry
    @State private var peak: Float = 0

    var body: some View {
        let apps = AppAudioController.shared
        let setting = apps.setting(for: entry.bundleID)
        HStack(spacing: 8) {
            AppIconView(bundleID: entry.bundleID, size: 20)
                .opacity(entry.isPlaying ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(setting.muted ? L("mixer.muted") : "\(Int(setting.volume * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(setting.volume) }, set: { apps.setVolume(Float($0), for: entry.bundleID) }), in: 0...1.5)
                    .controlSize(.mini)
                MeterBar(level: apps.hasActiveTap(entry.bundleID) ? apps.takePeak(for: entry.bundleID) : (entry.isPlaying ? 0.0 : 0))
            }
            Button { apps.toggleMute(for: entry.bundleID) } label: {
                Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.1")
                    .foregroundStyle(setting.muted ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(L("action.audio.setAppMuted"))
        }
    }
}

private struct MeterBar: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

/// Floating mixer panel opened by shortcut.
final class MixerPanelController {
    private unowned let runtime: KeystivoRuntime
    private var panel: FloatingPanel?

    init(runtime: KeystivoRuntime) { self.runtime = runtime }

    func toggle() {
        if panel?.isVisible == true { panel?.orderOut(nil); return }
        AppAudioController.shared.refresh()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.position(on: NSScreen.underMouse, topFraction: 0.15)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(level: .modalPanel)
        panel.host(
            MixerView(runtime: runtime)
                .padding(16)
                .frame(width: 360)
                .keystivoPanelBackground(),
            size: CGSize(width: 360, height: 460)
        )
        panel.onResignKey = { [weak panel] in DispatchQueue.main.async { panel?.orderOut(nil) } }
        return panel
    }
}
