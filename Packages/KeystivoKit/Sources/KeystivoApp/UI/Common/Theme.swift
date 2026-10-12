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

/// Design tokens shared by all Keystivo surfaces.
enum Theme {
    static let panelCornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 9
    static let launcherSize = CGSize(width: 760, height: 480)

    static func color(named name: String) -> Color {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        case "gray": .gray
        default: .blue
        }
    }

    static let colorNames = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "cyan", "brown", "gray"]

    #if DEBUG
    /// Marketing renders draw their own glass behind panels (system materials
    /// don't render offscreen), so panels leave their background out.
    nonisolated(unsafe) static var isShowcase = false
    #else
    static let isShowcase = false
    #endif
}

/// NSVisualEffectView bridge, used before macOS 26 (no Liquid Glass).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

extension View {
    /// Floating-surface background: Liquid Glass on macOS 26+, vibrancy before.
    @ViewBuilder
    func keystivoPanelBackground(cornerRadius: CGFloat = Theme.panelCornerRadius, material: NSVisualEffectView.Material = .hudWindow) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if Theme.isShowcase {
            self
        } else if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(VisualEffectBackground(material: material).clipShape(shape))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
    }

    /// Interactive glass for tiles and buttons on macOS 26+, tinted when active.
    @ViewBuilder
    func keystivoTileBackground(isOn: Bool, color: Color, cornerRadius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            self.glassEffect(isOn ? .regular.tint(color.opacity(0.55)).interactive() : .regular.interactive(), in: shape)
        } else {
            self.background(shape.fill(isOn ? color.opacity(0.85) : Color.primary.opacity(0.07)))
        }
    }

    /// Springs content from slightly smaller each time `token` changes.
    func popIn(token: Int) -> some View {
        modifier(PopInModifier(token: token))
    }

    /// Re-renders when the interface language changes.
    func localizedRoot() -> some View {
        modifier(LocalizedRootModifier())
    }
}

private struct PopInModifier: ViewModifier {
    let token: Int
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
            .onChange(of: token, initial: true) {
                scale = 0.965
                opacity = 0.6
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                    scale = 1
                    opacity = 1
                }
            }
    }
}

/// Animated gradient hairline used around focused surfaces.
struct GlowBorder: View {
    var cornerRadius: CGFloat = Theme.panelCornerRadius
    /// Each change plays one shimmer sweep (e.g. when a panel opens). The border
    /// is static otherwise: a looping animation keeps re-rendering the gradient
    /// in software, even while the panel is hidden.
    var token: Int = 0
    @State private var phase: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(colors: [.accentColor.opacity(0.7), .purple.opacity(0.5), .cyan.opacity(0.6), .accentColor.opacity(0.7)],
                                center: .center, angle: .degrees(phase)),
                lineWidth: 1.2
            )
            .opacity(0.65)
            .onAppear(perform: sweep)
            .onChange(of: token) { sweep() }
            .allowsHitTesting(false)
    }

    private func sweep() {
        withAnimation(.easeOut(duration: 1.4)) { phase += 240 }
    }
}

private struct LocalizedRootModifier: ViewModifier {
    func body(content: Content) -> some View {
        let localizer = Localizer.shared
        content
            .environment(\.locale, localizer.locale)
            .id(localizer.revision)
    }
}

/// Icon for an app by bundle ID or path.
struct AppIconView: View {
    var bundleID: String?
    var path: String?
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    private var image: NSImage {
        if let path { return AppIconCache.shared.icon(forPath: path) }
        return AppIconCache.shared.icon(forBundleID: bundleID)
    }
}

/// A rounded SF Symbol tile, used for commands and settings rows.
struct SymbolTile: View {
    var symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
    }
}

/// A keyboard shortcut rendered as key caps (⌃ ⌥ ⌘ K).
struct KeyCapsView: View {
    var combo: KeyCombo
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: compact ? 10 : 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, compact ? 4 : 5)
                    .padding(.vertical, compact ? 1 : 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(combo.displayString)
    }

    private var parts: [String] {
        var result: [String] = []
        let modifiers = combo.modifiers
        if modifiers.contains(.function) { result.append("fn") }
        if modifiers.contains(.control) { result.append("⌃") }
        if modifiers.contains(.option) { result.append("⌥") }
        if modifiers.contains(.shift) { result.append("⇧") }
        if modifiers.contains(.command) { result.append("⌘") }
        result.append(combo.keyDisplay)
        return result
    }
}

/// Small capsule label ("Beta", "On", counts…).
struct Badge: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
