// Renders the DMG window background (language-neutral: an arrow from the app
// to the Applications folder). Usage: swift Scripts/dmg-background.swift OUT_DIR
// Produces background.png (660×400) and background@2x.png; make-dmg.sh combines them.
import AppKit

let size = CGSize(width: 660, height: 400)
let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = CGRect(origin: .zero, size: size)

    // Soft vertical gradient.
    NSGradient(colors: [NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.99, alpha: 1),
                        NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.95, alpha: 1)])!
        .draw(in: bounds, angle: -90)

    // Subtle glow behind each icon slot (icons sit at x = 165 and 495, y = 190 from the top).
    for x in [165.0, 495.0] {
        let center = CGPoint(x: x, y: size.height - 190)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.9), NSColor.white.withAlphaComponent(0)])!
            .draw(fromCenter: center, radius: 0, toCenter: center, radius: 95, options: [])
    }

    // Curved arrow between the slots.
    let start = CGPoint(x: 245, y: size.height - 190)
    let end = CGPoint(x: 410, y: size.height - 190)
    let arrow = NSBezierPath()
    arrow.move(to: start)
    arrow.curve(to: end, controlPoint1: CGPoint(x: 290, y: size.height - 150), controlPoint2: CGPoint(x: 365, y: size.height - 150))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    let tint = NSColor(calibratedRed: 0.35, green: 0.40, blue: 0.95, alpha: 0.85)
    tint.setStroke()
    arrow.setLineDash([2, 11], count: 2, phase: 0)
    arrow.stroke()

    // Head follows the curve's tangent at the end point.
    let control2 = CGPoint(x: 365, y: size.height - 150)
    let length = hypot(end.x - control2.x, end.y - control2.y)
    let direction = CGPoint(x: (end.x - control2.x) / length, y: (end.y - control2.y) / length)
    let normal = CGPoint(x: -direction.y, y: direction.x)
    let tip = CGPoint(x: end.x + direction.x * 16, y: end.y + direction.y * 16)
    let back = CGPoint(x: end.x - direction.x * 4, y: end.y - direction.y * 4)
    let head = NSBezierPath()
    head.move(to: tip)
    head.line(to: CGPoint(x: back.x + normal.x * 11, y: back.y + normal.y * 11))
    head.line(to: CGPoint(x: back.x - normal.x * 11, y: back.y - normal.y * 11))
    head.close()
    tint.setFill()
    head.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render(scale: 1).write(to: outDir.appending(path: "background.png"))
try render(scale: 2).write(to: outDir.appending(path: "background@2x.png"))
print("wrote \(outDir.path)/background.png, background@2x.png")
