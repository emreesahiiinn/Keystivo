import SwiftUI

/// "Digital rain": three depth layers of falling, ever-changing glyph streams
/// with glowing heads, and a clock that decodes itself every minute.
///
/// Everything is a pure function of time (no stored state), so every display,
/// preview and thumbnail shows a consistent frame. Glyphs are pre-rendered once
/// as Canvas symbols and the scene is composited on the GPU.
struct RainDesign: View {
    let date: Date
    let scale: CGFloat
    let size: CGSize

    /// Mirrored half-width katakana, digits and a few symbols — the classic set.
    static let glyphs: [Character] = Array("ｦｱｳｴｵｶｷｹｺｻｼｽｾｿﾀﾂﾃﾅﾆﾇﾈﾊﾋﾎﾏﾐﾑﾒﾓﾔﾕﾗﾘﾜ012345789Z:.=*+-<>¦")
    static let katakanaCount = 36

    /// Colors along a stream; 0 is the head.
    static let shades: [Color] = [
        Color(red: 0.93, green: 1.00, blue: 0.95),
        Color(red: 0.62, green: 1.00, blue: 0.74),
        Color(red: 0.38, green: 0.98, blue: 0.56),
        Color(red: 0.22, green: 0.85, blue: 0.42),
        Color(red: 0.12, green: 0.63, blue: 0.29),
        Color(red: 0.06, green: 0.42, blue: 0.18),
    ]
    /// Characters the clock scrambles through (same width as digits).
    static let decodeGlyphs: [Character] = Array("0123456789ABCDEFXZ")
    static let symbolPointSize: CGFloat = 44

    struct Layer {
        let cell: CGFloat
        let speed: ClosedRange<Double>
        let density: Double
        let opacity: Double
        let blur: CGFloat
        let glow: Bool
        let seed: UInt64
    }

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        ZStack {
            Canvas(opaque: true, rendersAsynchronously: false) { context, canvas in
                draw(&context, canvas: canvas, t: t)
            } symbols: {
                ForEach(0..<(Self.shades.count * Self.glyphs.count), id: \.self) { tag in
                    Self.glyphSymbol(tag).tag(tag)
                }
            }
            .drawingGroup()

            RainAtmosphere(scale: scale).equatable()

            DecodingClock(date: date, scale: scale)
                .offset(SaverClock.drift(date, amplitude: 14 * scale))
        }
    }

    // MARK: Rain

    private func layers() -> [Layer] {
        let s = max(scale, 0.35)
        return [
            Layer(cell: 14 * s, speed: 5...9, density: 0.85, opacity: 0.45, blur: 1.4 * s, glow: false, seed: 11),
            Layer(cell: 21 * s, speed: 8...15, density: 0.9, opacity: 1, blur: 0, glow: true, seed: 23),
            Layer(cell: 34 * s, speed: 13...22, density: 0.22, opacity: 1, blur: 0, glow: true, seed: 37),
        ]
    }

    private func draw(_ context: inout GraphicsContext, canvas: CGSize, t: Double) {
        context.fill(Path(CGRect(origin: .zero, size: canvas)), with: .color(Color(red: 0, green: 0.025, blue: 0.012)))
        for layer in layers() {
            if layer.blur > 0 {
                context.drawLayer { sub in
                    sub.addFilter(.blur(radius: layer.blur))
                    drawStreams(&sub, layer: layer, canvas: canvas, t: t, headsOnly: false)
                }
            } else {
                if layer.glow {
                    // Bloom: a blurred, brighter copy of the heads underneath.
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: layer.cell * 0.45))
                        drawStreams(&glow, layer: layer, canvas: canvas, t: t, headsOnly: true)
                        drawStreams(&glow, layer: layer, canvas: canvas, t: t, headsOnly: true)
                    }
                }
                drawStreams(&context, layer: layer, canvas: canvas, t: t, headsOnly: false)
            }
        }
    }

    private func drawStreams(_ context: inout GraphicsContext, layer: Layer, canvas: CGSize, t: Double, headsOnly: Bool) {
        let columns = Int(canvas.width / layer.cell) + 1
        let rows = Int(canvas.height / layer.cell) + 2
        let glyphCount = Self.glyphs.count
        let shadeCount = Self.shades.count
        for column in 0..<columns {
            var random = SeededRandom(seed: layer.seed &* 1_000_003 &+ UInt64(column))
            guard random.next() < layer.density else { continue }
            let x = CGFloat(column) * layer.cell
            for _ in 0..<2 {
                let speed = layer.speed.lowerBound + random.next() * (layer.speed.upperBound - layer.speed.lowerBound)
                let length = 8 + Int(random.next() * 24)
                let gap = 1.5 + random.next() * 7
                let period = Double(rows + length) / speed + gap
                let local = (t + random.next() * period).truncatingRemainder(dividingBy: period)
                let head = Int(local * speed)
                guard head - length < rows else { continue }
                for trail in 0..<(headsOnly ? 1 : length) {
                    let row = head - trail
                    guard row >= 0, row < rows else { continue }
                    let shade = trail == 0 ? 0 : min(shadeCount - 1, 1 + trail * (shadeCount - 1) / length)
                    // Each cell mutates at its own pace.
                    let cell = Self.mix(UInt64(column) &* 73_856_093 ^ UInt64(row) &* 19_349_663 ^ layer.seed)
                    let rate = 0.5 + Double(cell % 1000) / 1000 * 2.5
                    let glyph = Int(Self.mix(cell &+ UInt64(max(0, t * rate))) % UInt64(glyphCount))
                    guard let symbol = context.resolveSymbol(id: shade * glyphCount + glyph) else { continue }
                    context.opacity = layer.opacity * (trail == 0 ? 1 : 1 - Double(trail) / Double(length + 1))
                    // Slightly larger than the cell so columns read as continuous streams.
                    let overlap = layer.cell * 0.09
                    context.draw(symbol, in: CGRect(x: x - overlap, y: CGFloat(row) * layer.cell - overlap, width: layer.cell + overlap * 2, height: layer.cell + overlap * 2))
                }
            }
            // Occasional glints: a still cell flashes bright for a moment.
            if !headsOnly, layer.glow {
                let slot = UInt64(max(0, t * 1.3))
                let flash = Self.mix(UInt64(column) &* 2_654_435_761 ^ slot ^ layer.seed)
                if flash % 61 == 0 {
                    let row = Int((flash >> 8) % UInt64(rows))
                    let phase = t * 1.3 - Double(slot)
                    if let symbol = context.resolveSymbol(id: Int((flash >> 16) % UInt64(glyphCount))) {
                        context.opacity = (1 - phase) * layer.opacity
                        context.draw(symbol, in: CGRect(x: x, y: CGFloat(row) * layer.cell, width: layer.cell, height: layer.cell))
                    }
                }
            }
        }
        context.opacity = 1
    }

    private static func glyphSymbol(_ tag: Int) -> some View {
        let glyph = tag % glyphs.count
        let shade = tag / glyphs.count
        return Text(String(glyphs[glyph]))
            .font(.system(size: symbolPointSize, weight: shade == 0 ? .bold : .medium, design: .monospaced))
            .foregroundStyle(shades[shade])
            .frame(width: symbolPointSize, height: symbolPointSize)
            // Katakana are mirrored, as in the original effect.
            .scaleEffect(x: glyph < katakanaCount ? -1 : 1, y: 1)
    }

    /// SplitMix64: cheap, well-distributed integer hash.
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Readability halo behind the clock, vignette and faint scanlines. Static, so
/// it is rendered once instead of every frame.
private struct RainAtmosphere: View, Equatable {
    let scale: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let radius = 560 * scale
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius * 1.25, y: center.y - radius * 0.75, width: radius * 2.5, height: radius * 1.5)),
                         with: .radialGradient(Gradient(stops: [.init(color: .black.opacity(0.88), location: 0), .init(color: .black.opacity(0.5), location: 0.55), .init(color: .clear, location: 1)]),
                                               center: center, startRadius: 0, endRadius: radius * 1.25))
            let corner = hypot(canvas.width, canvas.height) / 2
            context.fill(Path(CGRect(origin: .zero, size: canvas)),
                         with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.7)]), center: center, startRadius: corner * 0.55, endRadius: corner))
            var scanlines = Path()
            let step = max(2, 3 * scale)
            var y: CGFloat = 0
            while y < canvas.height {
                scanlines.addRect(CGRect(x: 0, y: y, width: canvas.width, height: max(0.5, scale * 0.8)))
                y += step
            }
            context.fill(scanlines, with: .color(.black.opacity(0.18)))
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// The time, which "decodes" from random glyphs whenever the minute changes.
private struct DecodingClock: View {
    let date: Date
    let scale: CGFloat

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        let elapsed = t - (t / 60).rounded(.down) * 60
        let time = Array(SaverClock.time(date))
        let text = String(time.enumerated().map { index, character -> Character in
            guard character.isNumber else { return character }
            // Digits settle left to right over the first ~1.5 s of a minute.
            let settlesAt = 0.3 + Double(index) * 0.22
            guard elapsed < settlesAt else { return character }
            let pick = RainDesign.mix(UInt64(index) &* 977 ^ UInt64(max(0, t * 18)))
            return RainDesign.decodeGlyphs[Int(pick % UInt64(RainDesign.decodeGlyphs.count))]
        })
        let green = Color(red: 0.42, green: 1, blue: 0.58)
        VStack(spacing: 16 * scale) {
            Text(text)
                .font(.system(size: 170 * scale, weight: .bold, design: .monospaced))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.86, green: 1, blue: 0.9), green], startPoint: .top, endPoint: .bottom))
                .shadow(color: green.opacity(0.85), radius: 10 * scale)
                .shadow(color: green.opacity(0.45), radius: 34 * scale)
            HStack(spacing: 14 * scale) {
                Rectangle().fill(green.opacity(0.5)).frame(width: 46 * scale, height: 1.5 * scale)
                Text(SaverClock.longDate(date).uppercased())
                    .font(.system(size: 22 * scale, weight: .semibold, design: .monospaced))
                    .tracking(6 * scale)
                    .foregroundStyle(green.opacity(0.85))
                Rectangle().fill(green.opacity(0.5)).frame(width: 46 * scale, height: 1.5 * scale)
            }
        }
        .shadow(color: .black, radius: 2 * scale)
    }
}
