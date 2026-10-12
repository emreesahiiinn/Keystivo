import SwiftUI

/// Entry point for every surface: the macOS screen saver, Settings previews
/// and thumbnails. Designs are laid out for 1440×900 and scaled to fit.
public struct SaverRootView: View {
    let style: SaverStyle
    let isPreview: Bool
    /// Renders a still frame at this moment (thumbnails, preview cards); nil = live.
    let fixedDate: Date?
    let backdrop: SaverBackdrop

    public init(style: SaverStyle, isPreview: Bool = false, fixedDate: Date? = nil, backdrop: SaverBackdrop = .design) {
        self.style = style
        self.isPreview = isPreview
        self.fixedDate = fixedDate
        self.backdrop = style.supportsBackdrop ? backdrop : .design
    }

    public var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 1440, proxy.size.height / 900)
            ZStack {
                if backdrop == .design { Color.black }
                if style == .shuffle, let fixedDate, backdrop == .design {
                    ShuffleCollage(date: fixedDate, size: proxy.size)
                } else if let fixedDate {
                    SaverDesign(style: style, date: fixedDate, scale: scale, size: proxy.size, live: false)
                } else if style == .shuffle {
                    // Pick the design once a second; each design then runs at its own pace.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let current = Self.resolved(style, at: context.date, clocksOnly: backdrop != .design)
                        LiveDesign(style: current, scale: scale, size: proxy.size, isPreview: isPreview)
                            .id(current)
                            .transition(.opacity.animation(.easeInOut(duration: 1.5)))
                    }
                } else {
                    LiveDesign(style: style, scale: scale, size: proxy.size, isPreview: isPreview)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .environment(\.saverDrawsBackground, backdrop == .design)
        }
        .ignoresSafeArea()
    }

    /// Shuffle shows each design for three minutes (only clocks over a see-through backdrop).
    static func resolved(_ style: SaverStyle, at date: Date, clocksOnly: Bool = false) -> SaverStyle {
        guard style == .shuffle else { return style }
        let pool = clocksOnly ? SaverStyle.rotating.filter(\.supportsBackdrop) : SaverStyle.rotating
        // Clocks set before 2001 give negative slots: wrap them into range too.
        let slot = Int((date.timeIntervalSinceReferenceDate / 180).rounded(.down).truncatingRemainder(dividingBy: 1_000_000))
        return pool[((slot % pool.count) + pool.count) % pool.count]
    }
}

/// Drives one design live at the frame rate it needs.
private struct LiveDesign: View {
    let style: SaverStyle
    let scale: CGFloat
    let size: CGSize
    let isPreview: Bool

    var body: some View {
        if let interval = style.frameInterval {
            TimelineView(.animation(minimumInterval: isPreview ? max(interval, 1.0 / 12) : interval)) { context in
                SaverDesign(style: style, date: context.date, scale: scale, size: size, live: true)
            }
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                SaverDesign(style: style, date: context.date, scale: scale, size: size, live: true)
            }
        }
    }
}

private struct SaverDesign: View {
    let style: SaverStyle
    let date: Date
    let scale: CGFloat
    let size: CGSize
    let live: Bool

    var body: some View {
        switch style {
        case .glass: GlassTheme(date: date, scale: scale)
        case .aurora: AuroraTheme(date: date, scale: scale, live: live)
        case .fluid: FluidTheme(date: date, scale: scale)
        case .nebula: NebulaTheme(date: date, scale: scale, live: live)
        case .ocean: OceanTheme(date: date, scale: scale, live: live)
        case .synthwave: SynthwaveTheme(date: date, scale: scale, live: live)
        case .flip: FlipTheme(date: date, scale: scale)
        case .analog: AnalogTheme(date: date, scale: scale)
        case .rain: RainDesign(date: date, scale: scale, size: size)
        case .minimal, .shuffle: MinimalTheme(date: date, scale: scale)
        }
    }
}

private struct ShuffleCollage: View {
    let date: Date
    let size: CGSize

    var body: some View {
        let styles: [SaverStyle] = [.aurora, .synthwave, .flip, .nebula]
        let tile = CGSize(width: size.width / 2, height: size.height / 2)
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { column in
                        SaverRootView(style: styles[row * 2 + column], isPreview: true, fixedDate: date)
                            .frame(width: tile.width, height: tile.height)
                    }
                }
            }
        }
        .overlay {
            Image(systemName: "shuffle")
                .font(.system(size: min(size.width, size.height) * 0.14, weight: .bold))
                .foregroundStyle(.white)
                .padding(min(size.width, size.height) * 0.07)
                .background(Circle().fill(.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
    }
}

// MARK: - Shared clock typography

/// Large, light time with a quiet date line, tuned for legibility on any background.
private struct ClockLabel: View {
    enum Placement { case center, topLeading, bottomLeading }

    let date: Date
    let scale: CGFloat
    var placement: Placement = .center
    var timeSize: CGFloat = 190
    var weight: Font.Weight = .thin
    var dateOpacity: Double = 0.78

    var body: some View {
        let alignment: HorizontalAlignment = placement == .center ? .center : .leading
        let time = SaverClock.hourMinute(date)
        VStack(alignment: alignment, spacing: 6 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
                Text("\(time.hour):\(time.minute)")
                    .font(.system(size: timeSize * scale, weight: weight))
                    .kerning(-timeSize * 0.025 * scale)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let period = time.period {
                    Text(period).font(.system(size: timeSize * 0.18 * scale, weight: .medium)).opacity(0.8)
                }
            }
            Text(SaverClock.longDate(date))
                .font(.system(size: timeSize * 0.15 * scale, weight: .medium))
                .kerning(0.5 * scale)
                .opacity(dateOpacity)
                .padding(.leading, placement == .center ? 0 : 6 * scale)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 24 * scale, y: 6 * scale)
        .animation(.smooth(duration: 0.6), value: time.minute)
        .offset(SaverClock.drift(date, amplitude: 16 * scale))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
        .padding(.horizontal, placement == .center ? 0 : 110 * scale)
        .padding(.vertical, placement == .center ? 0 : 96 * scale)
    }

    private var frameAlignment: Alignment {
        switch placement {
        case .center: .center
        case .topLeading: .topLeading
        case .bottomLeading: .bottomLeading
        }
    }
}

// MARK: - Shader themes

private struct AuroraTheme: View {
    let date: Date
    let scale: CGFloat
    let live: Bool

    var body: some View {
        ZStack {
            ShaderBackground(effect: .aurora, stillDate: live ? nil : date)
            ClockLabel(date: date, scale: scale, placement: .topLeading, timeSize: 150, weight: .ultraLight)
        }
    }
}

private struct NebulaTheme: View {
    let date: Date
    let scale: CGFloat
    let live: Bool

    var body: some View {
        ZStack {
            ShaderBackground(effect: .nebula, stillDate: live ? nil : date)
            ClockLabel(date: date, scale: scale, timeSize: 200, weight: .ultraLight)
        }
    }
}

private struct OceanTheme: View {
    let date: Date
    let scale: CGFloat
    let live: Bool

    var body: some View {
        ZStack {
            ShaderBackground(effect: .ocean, stillDate: live ? nil : date)
            ClockLabel(date: date, scale: scale, placement: .bottomLeading, timeSize: 170, weight: .thin)
        }
    }
}

private struct SynthwaveTheme: View {
    let date: Date
    let scale: CGFloat
    let live: Bool

    var body: some View {
        let time = SaverClock.hourMinute(date)
        ZStack {
            ShaderBackground(effect: .synthwave, stillDate: live ? nil : date)
            VStack(spacing: 10 * scale) {
                Text("\(time.hour):\(time.minute)" + (time.period.map { " \($0)" } ?? ""))
                    .font(.system(size: 118 * scale, weight: .black, design: .rounded))
                    .italic()
                    .monospacedDigit()
                    .kerning(2 * scale)
                    // Chrome: sky, horizon line, ground.
                    .foregroundStyle(LinearGradient(stops: [
                        .init(color: .white, location: 0), .init(color: Color(red: 0.55, green: 0.85, blue: 1), location: 0.45),
                        .init(color: Color(red: 0.12, green: 0.15, blue: 0.45), location: 0.52), .init(color: Color(red: 1, green: 0.45, blue: 0.85), location: 0.75),
                        .init(color: .white, location: 1),
                    ], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color(red: 1, green: 0.2, blue: 0.75).opacity(0.85), radius: 18 * scale)
                    .contentTransition(.numericText())
                Text(SaverClock.longDate(date).uppercased())
                    .font(.system(size: 22 * scale, weight: .semibold, design: .rounded))
                    .tracking(9 * scale)
                    .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 1))
                    .shadow(color: .cyan.opacity(0.7), radius: 8 * scale)
            }
            .offset(SaverClock.drift(date, amplitude: 10 * scale))
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 52 * scale)
        }
    }
}

// MARK: - Fluid colours

private struct FluidTheme: View {
    let date: Date
    let scale: CGFloat

    /// Nine colours each (3×3 mesh).
    private static let palettes: [[SIMD3<Double>]] = [
        // Dusk
        [[0.12, 0.07, 0.35], [0.45, 0.12, 0.55], [0.95, 0.35, 0.45],
         [0.25, 0.2, 0.6], [0.98, 0.5, 0.4], [1.0, 0.7, 0.4],
         [0.08, 0.05, 0.25], [0.6, 0.2, 0.55], [0.98, 0.82, 0.62]],
        // Lagoon
        [[0.0, 0.15, 0.3], [0.0, 0.45, 0.55], [0.2, 0.8, 0.75],
         [0.1, 0.3, 0.65], [0.3, 0.7, 0.85], [0.75, 0.95, 0.85],
         [0.05, 0.1, 0.35], [0.35, 0.25, 0.75], [0.1, 0.55, 0.6]],
        // Berry
        [[0.25, 0.0, 0.2], [0.75, 0.1, 0.4], [1.0, 0.4, 0.55],
         [0.15, 0.05, 0.35], [0.55, 0.2, 0.85], [1.0, 0.65, 0.75],
         [0.35, 0.05, 0.45], [0.9, 0.3, 0.6], [1.0, 0.8, 0.85]],
        // Citrus
        [[0.95, 0.45, 0.1], [1.0, 0.78, 0.25], [1.0, 0.9, 0.6],
         [0.75, 0.2, 0.3], [0.95, 0.3, 0.35], [1.0, 0.62, 0.3],
         [0.4, 0.15, 0.4], [0.7, 0.2, 0.45], [0.98, 0.5, 0.3]],
    ]

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        // Each palette holds for ~2 minutes and blends into the next over 20 s.
        let cycle = t / 140
        let count = Self.palettes.count
        let index = ((Int(cycle.truncatingRemainder(dividingBy: 1_000_000)) % count) + count) % count
        let blend = min(1, max(0, (cycle - floor(cycle) - 0.86) / 0.14))
        let from = Self.palettes[index], to = Self.palettes[(index + 1) % Self.palettes.count]
        let colors = (0..<9).map { slot -> Color in
            let c = from[slot] + (to[slot] - from[slot]) * blend
            return Color(red: c.x, green: c.y, blue: c.z)
        }
        ZStack {
            MeshGradient(width: 3, height: 3, points: Self.points(t), colors: colors, smoothsColors: true)
            // Fine grain keeps large gradients from looking flat or banded.
            GrainOverlay(opacity: 0.06)
            ClockLabel(date: date, scale: scale, timeSize: 210, weight: .ultraLight)
        }
    }

    private static func points(_ t: Double) -> [SIMD2<Float>] {
        func wobble(_ phase: Double, _ amount: Float) -> SIMD2<Float> {
            SIMD2(Float(sin(t / 7 + phase)) * amount, Float(cos(t / 9 + phase * 1.3)) * amount)
        }
        let top = wobble(1, 0.14), left = wobble(2, 0.14), middle = wobble(3, 0.2), right = wobble(4, 0.14), bottom = wobble(5, 0.14)
        return [
            [0, 0], [0.5 + top.x, 0], [1, 0],
            [0, 0.5 + left.y], [0.5 + middle.x, 0.5 + middle.y], [1, 0.5 + right.y],
            [0, 1], [0.5 + bottom.x, 1], [1, 1],
        ]
    }
}

/// Static film grain, generated once.
private struct GrainOverlay: View {
    let opacity: Double

    private static let tile: CGImage? = {
        let size = 192
        var random = SeededRandom(seed: 99)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = UInt8(random.next() * 255)
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
            pixels[index + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()

    var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: 2)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(opacity)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Flip clock

private struct FlipTheme: View {
    let date: Date
    let scale: CGFloat
    @Environment(\.saverDrawsBackground) private var drawsBackground

    var body: some View {
        let calendar = Calendar.current
        let now = SaverClock.hourMinute(date)
        let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let before = SaverClock.hourMinute(minuteStart.addingTimeInterval(-1))
        // The flip plays during the first 0.8 s of each minute.
        let progress = min(1, date.timeIntervalSince(minuteStart) / 0.8)
        ZStack {
            if drawsBackground {
                RadialGradient(colors: [Color(white: 0.11), Color(white: 0.02)], center: .center, startRadius: 0, endRadius: 1000 * scale)
            }
            VStack(spacing: 44 * scale) {
                HStack(spacing: 30 * scale) {
                    FlipCard(old: before.hour, new: now.hour, progress: before.hour == now.hour ? 1 : progress, scale: scale)
                    FlipCard(old: before.minute, new: now.minute, progress: progress, scale: scale)
                }
                .overlay(alignment: .bottomLeading) {
                    if let period = now.period {
                        Text(period)
                            .font(.system(size: 26 * scale, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(white: 0.85))
                            .padding(20 * scale)
                    }
                }
                Text(SaverClock.longDate(date).uppercased())
                    .font(.system(size: 22 * scale, weight: .semibold))
                    .tracking(7 * scale)
                    .foregroundStyle(Color(white: drawsBackground ? 0.5 : 0.85))
                    .shadow(color: .black.opacity(drawsBackground ? 0 : 0.5), radius: 10 * scale)
            }
            .offset(SaverClock.drift(date, amplitude: 14 * scale))
        }
    }
}

/// A split-flap card: when the value changes, the upper half folds down to
/// reveal the new value, then the lower flap falls into place.
private struct FlipCard: View {
    let old: String
    let new: String
    let progress: Double
    let scale: CGFloat

    private var size: CGSize { CGSize(width: 440 * scale, height: 470 * scale) }

    var body: some View {
        let firstHalf = min(1, progress * 2)
        let secondHalf = max(0, progress * 2 - 1)
        ZStack {
            VStack(spacing: 0) {
                half(new, top: true)          // revealed behind the falling flap
                half(progress < 1 ? old : new, top: false)
            }
            if progress < 1 {
                VStack(spacing: 0) {
                    // Upper flap with the old value folds down (0 → 90°).
                    half(old, top: true)
                        .overlay(Color.black.opacity(firstHalf * 0.55))
                        .rotation3DEffect(.degrees(-90 * firstHalf), axis: (1, 0, 0), anchor: .bottom, perspective: 0.45)
                        .opacity(firstHalf < 1 ? 1 : 0)
                    // Lower flap with the new value lands (90° → 0).
                    half(new, top: false)
                        .overlay(Color.black.opacity((1 - secondHalf) * 0.45))
                        .rotation3DEffect(.degrees(90 * (1 - secondHalf)), axis: (1, 0, 0), anchor: .top, perspective: 0.45)
                        .opacity(secondHalf > 0 ? 1 : 0)
                }
            }
            // Hinge.
            Rectangle().fill(Color.black.opacity(0.9)).frame(height: 4 * scale)
            HStack {
                Capsule().fill(Color(white: 0.05)).frame(width: 10 * scale, height: 30 * scale)
                Spacer()
                Capsule().fill(Color(white: 0.05)).frame(width: 10 * scale, height: 30 * scale)
            }
            .padding(.horizontal, -5 * scale)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.75), radius: 26 * scale, y: 18 * scale)
    }

    /// One half of a card face: the full card drawn, then cropped.
    private func half(_ text: String, top: Bool) -> some View {
        let radius = 30 * scale
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0, bottomLeadingRadius: top ? 0 : radius,
            bottomTrailingRadius: top ? 0 : radius, topTrailingRadius: top ? radius : 0, style: .continuous
        )
        return ZStack {
            LinearGradient(colors: top ? [Color(white: 0.2), Color(white: 0.15)] : [Color(white: 0.13), Color(white: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            Text(text)
                .font(.system(size: 360 * scale, weight: .bold, design: .rounded))
                .monospacedDigit()
                .kerning(-6 * scale)
                .foregroundStyle(Color(white: 0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .frame(width: size.width, height: size.height)
                .offset(y: top ? size.height / 4 : -size.height / 4)
        }
        .frame(width: size.width, height: size.height / 2)
        .clipShape(shape)
        .overlay(alignment: .top) {
            if top {
                // A hint of light on the top edge.
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1.5 * scale).padding(.horizontal, 24 * scale)
            }
        }
    }
}

// MARK: - Analog

private struct AnalogTheme: View {
    let date: Date
    let scale: CGFloat
    @Environment(\.saverDrawsBackground) private var drawsBackground

    var body: some View {
        let seconds = SaverClock.secondsOfDay(date)
        let day = Calendar.current.component(.day, from: date)
        ZStack {
            if drawsBackground {
                RadialGradient(colors: [Color(red: 0.09, green: 0.1, blue: 0.12), Color(red: 0.01, green: 0.01, blue: 0.02)],
                               center: .center, startRadius: 0, endRadius: 1000 * scale)
            }
            Canvas { context, size in
                WatchFace.draw(in: &context, size: size, seconds: seconds, day: day, scale: scale)
            }
            .frame(width: 780 * scale, height: 780 * scale)
            .offset(SaverClock.drift(date, amplitude: 12 * scale))
        }
    }
}

private enum WatchFace {
    static let steel = Gradient(colors: [Color(white: 0.92), Color(white: 0.45), Color(white: 0.85), Color(white: 0.3),
                                         Color(white: 0.95), Color(white: 0.5), Color(white: 0.92)])
    static let lume = Color(red: 0.88, green: 0.97, blue: 0.9)

    static func draw(in context: inout GraphicsContext, size: CGSize, seconds: Double, day: Int, scale: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2 - 24 * scale
        let dial = outer - 34 * scale

        // Case shadow and polished steel bezel.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 26 * scale))
            layer.fill(circle(CGPoint(x: center.x, y: center.y + 12 * scale), outer), with: .color(.black.opacity(0.9)))
        }
        context.fill(circle(center, outer), with: .conicGradient(steel, center: center, angle: .degrees(-30)))
        context.stroke(circle(center, outer - 1), with: .color(.white.opacity(0.35)), lineWidth: 1.5 * scale)

        // Sunburst dial: fine conic stripes plus a vignette.
        let stops = (0...120).map { index in
            Gradient.Stop(color: index.isMultiple(of: 2) ? Color(red: 0.07, green: 0.2, blue: 0.43) : Color(red: 0.12, green: 0.28, blue: 0.56),
                          location: Double(index) / 120)
        }
        context.fill(circle(center, dial), with: .conicGradient(Gradient(stops: stops), center: center))
        context.fill(circle(center, dial), with: .radialGradient(Gradient(colors: [.white.opacity(0.06), .clear, .black.opacity(0.55)]),
                                                                center: center, startRadius: 0, endRadius: dial))
        context.stroke(circle(center, dial), with: .color(.black.opacity(0.6)), lineWidth: 3 * scale)

        // Minute track.
        for tick in 0..<60 where !tick.isMultiple(of: 5) {
            let angle = Double(tick) / 60 * 2 * .pi
            var path = Path()
            path.move(to: point(center, angle, dial * 0.955))
            path.addLine(to: point(center, angle, dial * 0.993))
            context.stroke(path, with: .color(.white.opacity(0.55)), lineWidth: 1.6 * scale)
        }
        // Applied steel hour markers with lume (date window at three).
        for hour in 0..<12 where hour != 3 {
            let angle = Double(hour) / 12 * 2 * .pi
            let length: CGFloat = hour == 0 ? 0.17 : 0.12
            let width: CGFloat = (hour == 0 ? 24 : 15) * scale
            var marker = context
            marker.translateBy(x: center.x, y: center.y)
            marker.rotate(by: .radians(angle))
            let rect = CGRect(x: -width / 2, y: -dial * 0.94, width: width, height: dial * length)
            marker.fill(Path(roundedRect: rect.offsetBy(dx: 2 * scale, dy: 3 * scale), cornerRadius: 3 * scale), with: .color(.black.opacity(0.45)))
            marker.fill(Path(roundedRect: rect, cornerRadius: 3 * scale),
                        with: .linearGradient(steel, startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            marker.fill(Path(roundedRect: rect.insetBy(dx: width * 0.3, dy: 6 * scale), cornerRadius: 2 * scale), with: .color(lume))
        }
        // Brand and date window.
        context.draw(Text("KEYSTIVO").font(.system(size: 22 * scale, weight: .semibold)).kerning(5 * scale).foregroundColor(.white.opacity(0.92)),
                     at: CGPoint(x: center.x, y: center.y - dial * 0.4))
        context.draw(Text("AUTOMATIC").font(.system(size: 13 * scale, weight: .medium)).kerning(4 * scale).foregroundColor(Color(red: 1, green: 0.55, blue: 0.3)),
                     at: CGPoint(x: center.x, y: center.y + dial * 0.4))
        let window = CGRect(x: center.x + dial * 0.66, y: center.y - 22 * scale, width: 54 * scale, height: 44 * scale)
        context.fill(Path(roundedRect: window.insetBy(dx: -4 * scale, dy: -4 * scale), cornerRadius: 6 * scale),
                     with: .linearGradient(steel, startPoint: window.origin, endPoint: CGPoint(x: window.maxX, y: window.maxY)))
        context.fill(Path(roundedRect: window, cornerRadius: 4 * scale), with: .color(Color(white: 0.97)))
        context.draw(Text("\(day)").font(.system(size: 28 * scale, weight: .semibold)).foregroundColor(.black), at: CGPoint(x: window.midX, y: window.midY))

        // Hands, with shadows cast on the dial.
        let hourAngle = (seconds / 43_200).truncatingRemainder(dividingBy: 1) * 2 * .pi
        let minuteAngle = (seconds / 3_600).truncatingRemainder(dividingBy: 1) * 2 * .pi
        let secondAngle = (seconds / 60).truncatingRemainder(dividingBy: 1) * 2 * .pi
        let hands: [(angle: Double, length: CGFloat, width: CGFloat)] = [(hourAngle, dial * 0.56, 30 * scale), (minuteAngle, dial * 0.86, 22 * scale)]
        context.drawLayer { shadow in
            shadow.addFilter(.blur(radius: 8 * scale))
            shadow.translateBy(x: 6 * scale, y: 10 * scale)
            for hand in hands { shadow.fill(dauphine(center, hand.angle, hand.length, hand.width), with: .color(.black.opacity(0.6))) }
        }
        for hand in hands {
            context.fill(dauphine(center, hand.angle, hand.length, hand.width),
                         with: .linearGradient(steel, startPoint: point(center, hand.angle - .pi / 2, hand.width), endPoint: point(center, hand.angle + .pi / 2, hand.width)))
            // Faceted edge: one half catches less light.
            var facet = Path()
            facet.move(to: point(center, hand.angle + .pi, hand.length * 0.12))
            facet.addLine(to: point(center, hand.angle + .pi / 2, hand.width / 2))
            facet.addLine(to: point(center, hand.angle, hand.length))
            facet.closeSubpath()
            context.fill(facet, with: .color(.black.opacity(0.28)))
            var lumeLine = Path()
            lumeLine.move(to: point(center, hand.angle, hand.length * 0.3))
            lumeLine.addLine(to: point(center, hand.angle, hand.length * 0.88))
            context.stroke(lumeLine, with: .color(lume), style: StrokeStyle(lineWidth: hand.width * 0.22, lineCap: .round))
        }
        // Seconds hand with a lollipop and counterweight.
        let orange = Color(red: 1, green: 0.42, blue: 0.16)
        var second = Path()
        second.move(to: point(center, secondAngle + .pi, dial * 0.22))
        second.addLine(to: point(center, secondAngle, dial * 0.92))
        context.drawLayer { shadow in
            shadow.addFilter(.blur(radius: 4 * scale))
            shadow.translateBy(x: 4 * scale, y: 7 * scale)
            shadow.stroke(second, with: .color(.black.opacity(0.5)), lineWidth: 3 * scale)
        }
        context.stroke(second, with: .color(orange), style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round))
        context.fill(circle(point(center, secondAngle, dial * 0.7), 9 * scale), with: .color(orange))
        context.fill(circle(point(center, secondAngle + .pi, dial * 0.18), 7 * scale), with: .color(orange))
        context.fill(circle(center, 14 * scale),
                     with: .linearGradient(steel, startPoint: CGPoint(x: center.x - 14 * scale, y: center.y - 14 * scale), endPoint: CGPoint(x: center.x + 14 * scale, y: center.y + 14 * scale)))
        context.fill(circle(center, 5 * scale), with: .color(orange))
        // Crystal reflection.
        var glare = Path()
        glare.addArc(center: center, radius: dial * 0.9, startAngle: .degrees(200), endAngle: .degrees(290), clockwise: false)
        context.stroke(glare, with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: dial * 0.12, lineCap: .round))
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func point(_ center: CGPoint, _ angle: Double, _ length: CGFloat) -> CGPoint {
        CGPoint(x: center.x + sin(angle) * length, y: center.y - cos(angle) * length)
    }

    /// A tapered "dauphine" hand.
    private static func dauphine(_ center: CGPoint, _ angle: Double, _ length: CGFloat, _ width: CGFloat) -> Path {
        var path = Path()
        path.move(to: point(center, angle + .pi, length * 0.12))
        path.addLine(to: point(center, angle - .pi / 2, width / 2))
        path.addLine(to: point(center, angle, length))
        path.addLine(to: point(center, angle + .pi / 2, width / 2))
        path.closeSubpath()
        return path
    }
}

// MARK: - Minimal (editorial)

private struct MinimalTheme: View {
    let date: Date
    let scale: CGFloat
    @Environment(\.saverDrawsBackground) private var drawsBackground

    var body: some View {
        let accent = Color(red: 1, green: 0.62, blue: 0.26)
        let time = SaverClock.hourMinute(date)
        ZStack {
            if drawsBackground {
                Color(red: 0.045, green: 0.043, blue: 0.05)
                GrainOverlay(opacity: 0.07)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.wide)).uppercased())
                    .font(.system(size: 22 * scale, weight: .semibold))
                    .tracking(10 * scale)
                    .foregroundStyle(accent)
                HStack(alignment: .firstTextBaseline, spacing: 14 * scale) {
                    Text("\(time.hour):\(time.minute)")
                        .font(.system(size: 270 * scale, weight: .ultraLight))
                        .kerning(-10 * scale)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let period = time.period {
                        Text(period).font(.system(size: 40 * scale, weight: .light)).opacity(0.7)
                    }
                }
                .padding(.top, -10 * scale)
                Text(date.formatted(.dateTime.day().month(.wide).year()))
                    .font(.system(size: 46 * scale, weight: .regular, design: .serif))
                    .italic()
                    .opacity(0.72)
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 560 * scale, height: max(1, scale))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(accent).frame(width: 560 * scale * SaverClock.secondsOfDay(date) / 86_400, height: max(1, scale))
                    }
                    .padding(.top, 42 * scale)
                WeekStrip(date: date, scale: scale, accent: accent)
                    .padding(.top, 30 * scale)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(drawsBackground ? 0 : 0.45), radius: 18 * scale, y: 4 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 150 * scale)
            .offset(SaverClock.drift(date, amplitude: 12 * scale))
        }
    }
}

private struct WeekStrip: View {
    let date: Date
    let scale: CGFloat
    let accent: Color

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        HStack(spacing: 30 * scale) {
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: date)
                VStack(spacing: 10 * scale) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 18 * scale, weight: .semibold))
                        .opacity(isToday ? 1 : 0.4)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 26 * scale, weight: isToday ? .semibold : .light))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? Color.black : Color.white.opacity(0.75))
                        .frame(width: 50 * scale, height: 50 * scale)
                        .background(Circle().fill(isToday ? accent : .clear))
                }
            }
        }
    }
}

// MARK: - Glass

/// A frosted glass card holding the time, over slowly drifting color — or over
/// the desktop itself when Keystivo runs it see-through.
private struct GlassTheme: View {
    let date: Date
    let scale: CGFloat
    @Environment(\.saverDrawsBackground) private var drawsBackground

    var body: some View {
        let time = SaverClock.hourMinute(date)
        let radius = 70 * scale
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if drawsBackground {
                GlassBackdrop(time: date.timeIntervalSinceReferenceDate)
                GrainOverlay(opacity: 0.05)
            }
            VStack(spacing: 14 * scale) {
                HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
                    Text("\(time.hour):\(time.minute)")
                        .font(.system(size: 230 * scale, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .kerning(-5 * scale)
                        .contentTransition(.numericText())
                    if let period = time.period {
                        Text(period).font(.system(size: 40 * scale, weight: .medium, design: .rounded)).opacity(0.75)
                    }
                }
                Text(SaverClock.longDate(date))
                    .font(.system(size: 34 * scale, weight: .medium, design: .rounded))
                    .opacity(0.78)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 12 * scale, y: 3 * scale)
            .animation(.smooth(duration: 0.6), value: time.minute)
            .padding(.horizontal, 110 * scale)
            .padding(.vertical, 70 * scale)
            .background {
                ZStack {
                    if drawsBackground {
                        shape.fill(.ultraThinMaterial)
                    }
                    shape.fill(Color.white.opacity(drawsBackground ? 0.06 : 0.1))
                    // Light catching the top-left edge.
                    shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)], startPoint: .topLeading, endPoint: .center))
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.25)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5 * scale)
                }
                .shadow(color: .black.opacity(0.28), radius: 60 * scale, y: 30 * scale)
            }
            .environment(\.colorScheme, .dark)
            .offset(SaverClock.drift(date, amplitude: 18 * scale))
        }
    }
}

/// Deep, slowly moving color for the glass to sit on.
private struct GlassBackdrop: View {
    let time: TimeInterval

    var body: some View {
        let t = time / 14
        func wave(_ phase: Double, _ amount: Float) -> Float { Float(sin(t + phase)) * amount }
        // Edge points slide along their edge only, so the color always fills the screen.
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5 + wave(0.4, 0.12), 0], [1, 0],
            [0, 0.5 + wave(1.3, 0.1)], [0.5 + wave(2.1, 0.14), 0.5 + wave(2.9, 0.12)], [1, 0.5 + wave(3.2, 0.1)],
            [0, 1], [0.5 + wave(4.4, 0.12), 1], [1, 1],
        ]
        // Stays among blues, violets and roses: never muddy greens or browns.
        let drift = sin(time / 420) * 0.07
        func tone(_ hue: Double, _ saturation: Double, _ brightness: Double) -> Color {
            Color(hue: (hue + drift + 1).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness)
        }
        return MeshGradient(width: 3, height: 3, points: points, colors: [
            tone(0.66, 0.80, 0.20), tone(0.72, 0.70, 0.38), tone(0.78, 0.62, 0.30),
            tone(0.60, 0.75, 0.32), tone(0.88, 0.50, 0.58), tone(0.74, 0.62, 0.42),
            tone(0.63, 0.85, 0.16), tone(0.69, 0.72, 0.30), tone(0.94, 0.55, 0.36),
        ])
    }
}
