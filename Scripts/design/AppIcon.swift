// Renders Keystivo's app icon (1024×1024) and every size the asset catalog needs.
// Usage: swift Scripts/design/AppIcon.swift OUTPUT_DIR
import AppKit
import SwiftUI

extension Color {
    init(_ hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Four-point sparkle.
struct Sparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let w = r * 0.22
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
        return path
    }
}

struct AppIcon: View {
    private let body824: CGFloat = 824
    private let radius: CGFloat = 186

    var body: some View {
        ZStack {
            plate
            keycap
                .frame(width: 452, height: 452)
                .offset(y: 10)
        }
        .frame(width: 1024, height: 1024)
    }

    private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Color(0x0D1030), Color(0x241C78), Color(0x4B32D6)], startPoint: .bottomLeading, endPoint: .topTrailing))
            .overlay(RadialGradient(colors: [Color(0x9A86FF, opacity: 0.75), .clear], center: UnitPoint(x: 0.82, y: 0.12), startRadius: 0, endRadius: 560).clipShape(shape))
            .overlay(RadialGradient(colors: [Color(0x18C8FF, opacity: 0.28), .clear], center: UnitPoint(x: 0.1, y: 0.95), startRadius: 0, endRadius: 520).clipShape(shape))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.04), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 3))
            .frame(width: body824, height: body824)
            .shadow(color: .black.opacity(0.38), radius: 28, y: 16)
    }

    private var keycap: some View {
        ZStack {
            // Walls of the key, seen below the top face.
            RoundedRectangle(cornerRadius: 108, style: .continuous)
                .fill(LinearGradient(colors: [Color(0xB7BAE3), Color(0x6E70A8)], startPoint: .top, endPoint: .bottom))
                .offset(y: 26)
            RoundedRectangle(cornerRadius: 108, style: .continuous)
                .fill(LinearGradient(colors: [Color(0xDADCF6), Color(0x9C9FD0)], startPoint: .top, endPoint: .bottom))
            // Slightly dished top face.
            RoundedRectangle(cornerRadius: 92, style: .continuous)
                .fill(LinearGradient(colors: [Color(0xFFFFFF), Color(0xEEEFFC), Color(0xE0E2F8)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 92, style: .continuous).strokeBorder(.white, lineWidth: 2))
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 44)
            // Indicator light, like Caps Lock's: Keystivo's Hyper key lives there.
            Capsule()
                .fill(LinearGradient(colors: [Color(0x9BF6FF), Color(0x23C7F2)], startPoint: .top, endPoint: .bottom))
                .frame(width: 58, height: 14)
                .shadow(color: Color(0x3FD8FF, opacity: 0.95), radius: 12)
                .offset(x: -118, y: -138)
            Text("K")
                .font(.system(size: 236, weight: .black, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [Color(0x3524B8), Color(0x6B4CF2)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .white.opacity(0.9), radius: 0, y: 2)
                .offset(y: -12)
        }
        .compositingGroup()
        .shadow(color: Color(0x05041F, opacity: 0.6), radius: 34, y: 30)
    }
}

@MainActor
func render(_ size: Int, to url: URL) throws {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = CGFloat(size) / 1024
    guard let image = renderer.cgImage else { throw NSError(domain: "icon", code: 1) }
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    let sizes: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for (name, size) in sizes { try? render(size, to: output.appending(path: name)) }
    try? render(1024, to: output.appending(path: "icon_1024.png"))
}
