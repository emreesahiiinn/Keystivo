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

/// Click, then press a shortcut. ⌫ clears, ⎋ cancels. Global hotkeys are
/// suspended while recording so the pressed chord doesn't trigger anything.
struct KeyRecorder: View {
    @Binding var combo: KeyCombo?
    var allowsUnmodified = false
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                HStack(spacing: 6) {
                    if isRecording {
                        Image(systemName: "record.circle").foregroundStyle(.red)
                        Text(L("recorder.recording")).foregroundStyle(.secondary)
                    } else if let combo {
                        KeyCapsView(combo: combo)
                    } else {
                        Text(L("recorder.placeholder")).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(minWidth: 120, minHeight: 22)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isRecording ? 0.1 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(combo?.displayString ?? L("recorder.placeholder"))
            if combo != nil, !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L("recorder.clear"))
            }
        }
        .popover(isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Text(message ?? "").padding(10).frame(maxWidth: 260)
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        KeystivoRuntime.shared.hotkeys.suspend(true)
        TapHotKeys.shared.isSuspended = true
        // The event tap sees chords macOS would otherwise swallow (⌘⇥, ⌘Space…).
        if KeyCaptureTap.shared.isAvailable {
            KeyCaptureTap.shared.begin { candidate in handle(candidate) }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(KeyCombo(keyCode: event.keyCode, modifiers: KeyModifiers(event.modifierFlags).subtracting(.function)))
            return nil
        }
    }

    private func stop() {
        isRecording = false
        KeystivoRuntime.shared.hotkeys.suspend(false)
        TapHotKeys.shared.isSuspended = false
        KeyCaptureTap.shared.end()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ candidate: KeyCombo) {
        guard isRecording else { return }
        if candidate.modifiers.isEmpty, candidate.keyCode == KeyCodes.escape { stop(); return }
        if candidate.modifiers.isEmpty, candidate.keyCode == KeyCodes.delete { combo = nil; stop(); return }
        guard allowsUnmodified || candidate.isValidGlobalShortcut else {
            message = L("hotkey.error.invalid")
            return
        }
        if TapHotKeys.systemReservedCombos.contains(candidate), !KeyCaptureTap.shared.isAvailable {
            message = L("hotkey.error.needsAccessibility")
        }
        combo = candidate
        stop()
    }
}
