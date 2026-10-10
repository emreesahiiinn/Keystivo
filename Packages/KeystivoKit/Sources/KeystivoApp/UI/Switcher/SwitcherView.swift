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

struct SwitcherView: View {
    let model: SwitcherModel
    let onSelect: (Int) -> Void
    @Namespace private var selectionNamespace

    var body: some View {
        let cardWidth = model.showsThumbnails ? model.thumbnailWidth : 120
        VStack(spacing: 10) {
            HStack {
                if let group = model.groupFilter {
                    Label(group.name, systemImage: group.symbolName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Spacer()
                Text(L("switcher.hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(height: 16)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: SwitcherLayout.spacing), count: columnCount(cardWidth)), spacing: SwitcherLayout.spacing) {
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, window in
                            SwitcherCard(window: window, isSelected: index == model.selectedIndex, width: cardWidth, showsThumbnail: model.showsThumbnails, namespace: selectionNamespace)
                                .id(window.id)
                                .onTapGesture { onSelect(index) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.selectedIndex)
                .onChange(of: model.selectedIndex) { _, index in
                    if model.entries.indices.contains(index) { proxy.scrollTo(model.entries[index].id) }
                }
            }
        }
        .padding(SwitcherLayout.padding)
        .keystivoPanelBackground(cornerRadius: 22)
        .overlay(GlowBorder(cornerRadius: 22))
        .popIn(token: model.openToken)
    }

    private func columnCount(_ cardWidth: CGFloat) -> Int {
        let maxWidth = (NSScreen.underMouse?.visibleFrame.width ?? 1400) * 0.9
        return SwitcherLayout.columns(count: model.entries.count, cardWidth: cardWidth, maxWidth: maxWidth)
    }
}

private struct SwitcherCard: View {
    let window: WindowInfo
    let isSelected: Bool
    let width: CGFloat
    let showsThumbnail: Bool
    let namespace: Namespace.ID

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                if showsThumbnail {
                    thumbnail
                        .frame(width: width - 12, height: width * 0.62 - 12)
                    AppIconView(bundleID: window.bundleID, size: 30)
                        .shadow(radius: 3)
                        .offset(x: -4, y: 6)
                } else {
                    AppIconView(bundleID: window.bundleID, size: 64)
                        .frame(width: width - 12, height: 72)
                }
            }
            HStack(spacing: 4) {
                if window.isMinimized { Image(systemName: "minus.square").font(.caption2) }
                if window.isOnOtherSpace { Image(systemName: "square.on.square.dashed").font(.caption2) }
                Text(window.displayTitle)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(width: width - 16)
        }
        .padding(6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                    .shadow(color: Color.accentColor.opacity(0.45), radius: 14)
                    .matchedGeometryEffect(id: "switcher-selection", in: namespace)
            }
        }
        .scaleEffect(isSelected ? 1.04 : 0.98)
        .zIndex(isSelected ? 1 : 0)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.appName), \(window.displayTitle)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = ThumbnailService.shared.images[window.id] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(AppIconView(bundleID: window.bundleID, size: 48).opacity(0.7))
        }
    }
}
