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

/// First-run welcome: language, permissions with clear reasons, key shortcuts.
struct OnboardingView: View {
    @Bindable var runtime: KeystivoRuntime
    let onFinish: () -> Void
    @State private var step = 0
    @Namespace private var dots

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome.transition(.push(from: .trailing))
                case 1: permissions.transition(.push(from: .trailing))
                default: shortcuts.transition(.push(from: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Capsule()
                            .fill(index == step ? Color.accentColor : Color.primary.opacity(0.2))
                            .frame(width: index == step ? 22 : 7, height: 7)
                            .animation(.spring(response: 0.35), value: step)
                    }
                }
                Spacer()
                if step > 0 {
                    Button(L("onboarding.back")) { step -= 1 }
                }
                Button(step == 2 ? L("onboarding.start") : L("onboarding.next")) {
                    if step == 2 {
                        runtime.config.general.hasCompletedOnboarding = true
                        onFinish()
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 720, height: 560)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.18), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 120, height: 120)
                .shadow(color: .accentColor.opacity(0.45), radius: 30, y: 10)
                .symbolEffect(.bounce, value: step)
            Text(L("onboarding.welcomeTitle")).font(.system(size: 30, weight: .bold))
            Text(L("onboarding.welcomeBody"))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Picker(L("general.interfaceLanguage"), selection: $runtime.config.general.language) {
                Text(L("general.language.system")).tag(AppLanguage.systemCode)
                ForEach(AppLanguage.supported) { Text($0.nativeName).tag($0.code) }
            }
            .frame(width: 320)
        }
        .padding(40)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("onboarding.permissionsTitle")).font(.title.weight(.bold))
            Text(L("onboarding.permissionsBody")).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(PermissionKind.allCases) { kind in
                        PermissionRow(kind: kind)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            Text(L("onboarding.permissionsFooter")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .onAppear { PermissionCenter.shared.startWatching(duration: 120) }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("onboarding.shortcutsTitle")).font(.title.weight(.bold))
            Text(L("onboarding.shortcutsBody")).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                ForEach(highlights, id: \.0) { actionID, symbol in
                    GridRow {
                        SymbolTile(symbol: symbol, color: .accentColor, size: 28)
                        Text(L("action.\(actionID)"))
                        if let combo = runtime.config.hotkeys.first(where: { $0.actions.first?.actionID == actionID })?.combo {
                            KeyCapsView(combo: combo)
                        } else if actionID == "windows.switcher", runtime.config.switcher.replacesCommandTab {
                            KeyCapsView(combo: KeyCombo(keyCode: KeyCodes.tab, modifiers: .command))
                        }
                    }
                }
            }
            Spacer()
            Text(L("onboarding.shortcutsFooter")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
    }

    private var highlights: [(String, String)] {
        [
            ("launcher.show", "magnifyingglass"), ("windows.switcher", "rectangle.on.rectangle"),
            ("clipboard.history", "clipboard"), ("navigation.hints", "keyboard.badge.ellipsis"),
            ("navigation.scroll", "scroll"), ("audio.showMixer", "slider.horizontal.3"),
        ]
    }
}
