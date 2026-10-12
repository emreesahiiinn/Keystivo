import AppKit
import KeystivoCore
import SwiftUI

/// Building blocks of Keystivo's menu bar panels, drawn for glass: quiet cards,
/// one accent color for "on", wide sliders and menu-like rows.
enum CC {
    static let cardRadius: CGFloat = 10
    static let titleFont = Font.system(size: 11, weight: .semibold)
    static let rowFont = Font.system(size: 12.5)
}

/// A group of related controls with an optional caption and accessory.
struct CCCard<Content: View, Accessory: View>: View {
    var title: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(spacing: 6) {
                    if let title { Text(title).font(CC.titleFont).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    accessory()
                }
                .frame(minHeight: 16)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CC.cardRadius, style: .continuous).fill(Color.primary.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: CC.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

/// A round on/off button with a caption (Control Center style, one accent color).
struct CCToggle: View {
    let symbol: String
    let title: String
    let isOn: Bool
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.16 : 0.1))))
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isOn)
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A wide slider with its symbol inside the track; tapping the symbol runs `onSymbol`.
struct CCSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let symbol: String
    var height: CGFloat = 22
    var label: String = ""
    var onSymbol: (() -> Void)?

    private var fraction: CGFloat {
        CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13))
                Capsule()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: height + (width - height) * fraction)
                Image(systemName: symbol)
                    .font(.system(size: height * 0.48, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: height, height: height)
                    .contentShape(Rectangle())
                    .onTapGesture { onSymbol?() }
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard drag.startLocation.x > height || onSymbol == nil else { return }
                let position = min(max((drag.location.x - height / 2) / max(width - height, 1), 0), 1)
                value = range.lowerBound + Double(position) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 16
            value = min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}

/// A menu-like row: symbol, title and (optionally) its keyboard shortcut.
struct CCRow: View {
    let symbol: String
    let title: String
    var shortcut: KeyCombo?
    var shortcutText: String?
    var isDestructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isDestructive ? Color.red : Color.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(CC.rowFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let shortcut {
                    KeyCapsView(combo: shortcut, compact: true)
                } else if let shortcutText {
                    Text(shortcutText).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small square icon button with hover feedback.
struct CCIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A compact borderless menu showing its current value (device, profile…).
struct CCMenu<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 3) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Header icon button (search, customize).
struct CCHeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
