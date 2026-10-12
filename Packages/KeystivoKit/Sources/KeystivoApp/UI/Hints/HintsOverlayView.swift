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

/// Draws hint labels for the elements on one screen.
struct HintsOverlayView: View {
    let model: HintsModel
    /// The screen's frame in AX coordinates, to map element frames to local space.
    let screenFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if model.isScrollMode {
                scrollOverlay
            } else if model.isSearching {
                searchOverlay
            } else {
                labelsOverlay
            }
            if isPrimaryScreen {
                statusBar
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private var isPrimaryScreen: Bool {
        guard let mouse = NSScreen.underMouse else { return screenFrame.origin == .zero }
        return ScreenGeometry.frameAX(of: mouse) == screenFrame
    }

    // MARK: Labels

    private var labelsOverlay: some View {
        ForEach(indicesOnScreen, id: \.self) { index in
            if model.visible.contains(index), model.labels.indices.contains(index) {
                HintLabel(text: model.labels[index], typedCount: model.typed.count, style: model.style, fontSize: model.fontSize)
                    .position(labelPosition(for: model.elements[index].frame))
            }
        }
    }

    private var indicesOnScreen: [Int] {
        model.elements.indices.filter { screenFrame.intersects(model.elements[$0].frame) }
    }

    private func labelPosition(for frame: CGRect) -> CGPoint {
        let x = frame.minX - screenFrame.minX + min(frame.width / 2, 14)
        let y = frame.midY - screenFrame.minY
        return CGPoint(x: max(12, x), y: max(10, y))
    }

    // MARK: Search

    private var searchOverlay: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.searchResults.prefix(40).enumerated()), id: \.offset) { position, index in
                let frame = model.elements.indices.contains(index) ? model.elements[index].frame : .null
                if !frame.isNull, screenFrame.intersects(frame) {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(position == model.searchSelection ? Color.accentColor : Color.yellow.opacity(0.8), lineWidth: position == model.searchSelection ? 3 : 1.5)
                        .background(RoundedRectangle(cornerRadius: 5).fill((position == model.searchSelection ? Color.accentColor : Color.yellow).opacity(0.15)))
                        .frame(width: frame.width + 6, height: frame.height + 6)
                        .position(x: frame.midX - screenFrame.minX, y: frame.midY - screenFrame.minY)
                }
            }
        }
    }

    // MARK: Scroll

    private var scrollOverlay: some View {
        ZStack(alignment: .topLeading) {
            ForEach(indicesOnScreen, id: \.self) { index in
                let frame = model.elements[index].frame
                let isSelected = model.scrollSelection == index
                if model.scrollSelection == nil || isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0.5), style: StrokeStyle(lineWidth: isSelected ? 3 : 2, dash: isSelected ? [] : [6, 4]))
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX - screenFrame.minX, y: frame.midY - screenFrame.minY)
                    if model.scrollSelection == nil, model.labels.indices.contains(index) {
                        HintLabel(text: model.labels[index], typedCount: model.typed.count, style: model.style, fontSize: model.fontSize + 4)
                            .position(x: frame.midX - screenFrame.minX, y: frame.midY - screenFrame.minY)
                    }
                }
            }
        }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isScrollMode ? "scroll" : (model.isSearching ? "text.magnifyingglass" : "keyboard"))
            if model.isSearching {
                Text(model.typed.isEmpty ? L("hints.searchPlaceholder") : model.typed)
                    .foregroundStyle(model.typed.isEmpty ? .secondary : .primary)
                    .frame(minWidth: 160, alignment: .leading)
            } else {
                Text(L(model.isScrollMode ? (model.scrollSelection == nil ? "hints.status.chooseArea" : "hints.status.scrolling") : "hints.status.labels"))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .keystivoPanelBackground(cornerRadius: 12)
        .modifier(Shake(animatableData: CGFloat(model.shakeToken)))
        .animation(.default, value: model.shakeToken)
        .position(x: screenFrame.width / 2, y: screenFrame.height - 70)
    }
}

private struct HintLabel: View {
    let text: String
    let typedCount: Int
    let style: HintStyle
    let fontSize: CGFloat
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            Text(String(text.prefix(typedCount))).opacity(0.45)
            Text(String(text.dropFirst(typedCount)))
        }
        .font(.system(size: fontSize, weight: .bold, design: .rounded))
        .foregroundStyle(foreground)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(background))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .fixedSize()
        .scaleEffect(appeared ? 1 : 0.4)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.62).delay(Double.random(in: 0...0.07))) { appeared = true }
        }
    }

    private var background: Color {
        switch style {
        case .accent: .accentColor
        case .yellow: Color(red: 1, green: 0.86, blue: 0.25)
        case .dark: .black.opacity(0.82)
        }
    }

    private var foreground: Color {
        style == .yellow ? .black : .white
    }
}

/// Horizontal shake used to signal a wrong key.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(animatableData * .pi * 4), y: 0))
    }
}
