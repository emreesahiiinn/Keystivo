#if DEBUG
import AppKit
import KeystivoCore
import KeystivoScreenSaver
import KeystivoTools
import SwiftUI

/// `-KSShowcase /output/dir`: renders the README's marketing images from the
/// real Keystivo views, in English, over a wallpaper-like backdrop with glass
/// drawn behind each panel. Sample data only: no clipboard history, files,
/// calendar events or device names of this Mac appear.
enum Showcase {
    static func run(runtime: KeystivoRuntime, output: URL) async {
        Theme.isShowcase = true
        runtime.store.suspendsSaving = true
        // `-KSShowcaseIcon /path.png`: the icon as designed (a debug build may show a cached one).
        if let path = UserDefaults.standard.string(forKey: "KSShowcaseIcon"), let icon = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = icon
        }
        Localizer.shared.setPreference("en")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        WeatherService.shared.refresh(city: city)
        for _ in 0..<40 where WeatherService.shared.report(for: city) == nil { try? await Task.sleep(for: .milliseconds(250)) }
        SystemMonitor.shared.acquire("showcase")
        try? await Task.sleep(for: .seconds(2.5))

        await save(hero(runtime: runtime), size: CGSize(width: 1600, height: 1000), to: output.appending(path: "hero.png"))
        await save(panels(runtime: runtime), size: CGSize(width: 1100, height: 1000), to: output.appending(path: "control-center.png"))
        await save(widgets(runtime: runtime), size: CGSize(width: 1180, height: 640), to: output.appending(path: "widgets.png"))

        let model = runtime.launcher.model
        model.isInertForTesting = true
        model.open(mode: .root)
        model.query = "window"
        try? await Task.sleep(for: .seconds(1.2))
        await save(launcherScene(model: model), size: CGSize(width: 1200, height: 760), to: output.appending(path: "launcher.png"))
        model.query = ""
        model.isInertForTesting = false

        SystemMonitor.shared.release("showcase")
        Theme.isShowcase = false
        Log.logger("Debug").notice("showcase: saved to \(output.path, privacy: .public)")
    }

    private static let city = "Barcelona"

    // MARK: Scenes

    private static func hero(runtime: KeystivoRuntime) -> some View {
        let canvas = CGSize(width: 1600, height: 1000)
        let panelHeight = controlCenterHeight(runtime: runtime)
        let panelFrame = CGRect(x: 1600 - 332 - 110, y: (1000 - panelHeight) / 2, width: 332, height: panelHeight)
        return ZStack(alignment: .topLeading) {
            Backdrop()
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 148, height: 148)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                Text("Keystivo")
                    .font(.system(size: 84, weight: .bold, design: .rounded))
                    .padding(.top, 18)
                Text("Every power tool your Mac is missing,\nin one fast, native app.")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.top, 6)
                FeatureChips(items: ["Launcher", "Clipboard", "Snippets", "Window snapping", "Switcher", "Keyboard hints",
                                     "Gestures", "Widgets", "Automation", "Sound mixer", "Screen tools"])
                    .frame(width: 760, alignment: .leading)
                    .padding(.top, 34)
            }
            .foregroundStyle(.white)
            .padding(.leading, 110)
            .padding(.top, 120)
            glass(CGRect(x: 110, y: 690, width: 344, height: 164), canvas: canvas, seed: 0, radius: 22) {
                WidgetView(runtime: runtime, instance: sample(.weather, .medium)).padding(14)
            }
            glass(CGRect(x: 478, y: 690, width: 164, height: 164), canvas: canvas, seed: 0, radius: 22) {
                WidgetView(runtime: runtime, instance: sample(.clock, .small)).padding(14)
            }
            glass(CGRect(x: 666, y: 690, width: 164, height: 164), canvas: canvas, seed: 0, radius: 22) {
                WidgetView(runtime: runtime, instance: sample(.timer, .small)).padding(14)
            }
            glass(panelFrame, canvas: canvas, seed: 0, radius: 14) {
                ControlCenterView(runtime: runtime)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
    }

    private static func panels(runtime: KeystivoRuntime) -> some View {
        let canvas = CGSize(width: 1100, height: 1000)
        let height = controlCenterHeight(runtime: runtime)
        let mixerHeight = NSHostingView(rootView: MixerPanelView(runtime: runtime).frame(width: 320).localizedRoot()).fittingSize.height
        return ZStack(alignment: .topLeading) {
            Backdrop(seed: 1)
            glass(CGRect(x: 150, y: (1000 - height) / 2, width: 332, height: height), canvas: canvas, seed: 1, radius: 14) {
                ControlCenterView(runtime: runtime)
            }
            glass(CGRect(x: 560, y: (1000 - height) / 2, width: 320, height: mixerHeight), canvas: canvas, seed: 1, radius: 14) {
                MixerPanelView(runtime: runtime)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
    }

    private static func widgets(runtime: KeystivoRuntime) -> some View {
        let canvas = CGSize(width: 1180, height: 640)
        let gap: CGFloat = 24
        let rows: [[WidgetInstance]] = [
            [sample(.clock, .small), sample(.weather, .medium), sample(.countdown, .small), sample(.timer, .small)],
            [sample(.worldClock, .medium), sample(.system, .medium), sample(.clock, .medium, analog: true)],
        ]
        var placed: [(WidgetInstance, CGRect)] = []
        var y: CGFloat = 70
        for row in rows {
            let width = row.map(\.size.points.width).reduce(0, +) + gap * CGFloat(row.count - 1)
            var x = (canvas.width - width) / 2
            for instance in row {
                placed.append((instance, CGRect(origin: CGPoint(x: x, y: y), size: instance.size.points)))
                x += instance.size.points.width + gap
            }
            y += 164 + gap
        }
        let shortcuts = sample(.shortcuts, .medium)
        let shortcutsFrame = CGRect(x: (canvas.width - 344 * 2 - gap) / 2, y: y, width: 344, height: 164)
        let calendarLike = sample(.worldClock, .medium, zones: ["Europe/Paris", "Asia/Dubai", "Australia/Sydney"])
        placed.append((shortcuts, shortcutsFrame))
        placed.append((calendarLike, shortcutsFrame.offsetBy(dx: 344 + gap, dy: 0)))
        return ZStack(alignment: .topLeading) {
            Backdrop(seed: 2)
            ForEach(Array(placed.enumerated()), id: \.offset) { _, item in
                glass(item.1, canvas: canvas, seed: 2, radius: 22) {
                    WidgetView(runtime: runtime, instance: item.0).padding(14)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
    }

    private static func launcherScene(model: LauncherModel) -> some View {
        let canvas = CGSize(width: 1200, height: 760)
        let size = Theme.launcherSize
        return ZStack(alignment: .topLeading) {
            Backdrop(seed: 3)
            glass(CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height),
                  canvas: canvas, seed: 3, radius: Theme.panelCornerRadius) {
                LauncherView(model: model)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Pieces

    private static func sample(_ kind: WidgetKind, _ size: WidgetSize, analog: Bool = false, zones: [String]? = nil) -> WidgetInstance {
        var instance = WidgetInstance(kind: kind, size: size)
        instance.city = city
        instance.title = "New Year"
        instance.showsSeconds = analog
        if let zones { instance.timeZones = zones }
        return instance
    }

    private static func controlCenterHeight(runtime: KeystivoRuntime) -> CGFloat {
        NSHostingView(rootView: ControlCenterView(runtime: runtime).frame(width: 332).localizedRoot()).fittingSize.height
    }

    /// Glass behind a panel: the backdrop under it, blurred and darkened, with a hairline edge.
    private static func glass<Content: View>(_ frame: CGRect, canvas: CGSize, seed: Int, radius: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content()
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .background {
                ZStack {
                    Backdrop(seed: seed)
                        .frame(width: canvas.width, height: canvas.height)
                        .offset(x: canvas.width / 2 - frame.midX, y: canvas.height / 2 - frame.midY)
                        .blur(radius: 34)
                    Color(red: 0.09, green: 0.09, blue: 0.13).opacity(0.62)
                }
                .frame(width: frame.width, height: frame.height)
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.4), radius: 34, y: 20)
            .offset(x: frame.minX, y: frame.minY)
    }

    private static func save<Content: View>(_ view: Content, size: CGSize, to url: URL) async {
        let window = NSWindow(contentRect: NSRect(x: -60_000, y: -60_000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.localizedRoot())
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(1.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

/// A calm, wallpaper-like mesh of deep blues and violets.
private struct Backdrop: View {
    var seed = 0

    var body: some View {
        let palettes: [[Color]] = [
            [.init(red: 0.05, green: 0.06, blue: 0.2), .init(red: 0.18, green: 0.12, blue: 0.45), .init(red: 0.42, green: 0.22, blue: 0.62),
             .init(red: 0.06, green: 0.2, blue: 0.42), .init(red: 0.34, green: 0.2, blue: 0.7), .init(red: 0.7, green: 0.32, blue: 0.62),
             .init(red: 0.03, green: 0.08, blue: 0.22), .init(red: 0.1, green: 0.22, blue: 0.5), .init(red: 0.45, green: 0.2, blue: 0.5)],
            [.init(red: 0.04, green: 0.08, blue: 0.18), .init(red: 0.08, green: 0.3, blue: 0.5), .init(red: 0.18, green: 0.5, blue: 0.62),
             .init(red: 0.1, green: 0.14, blue: 0.4), .init(red: 0.25, green: 0.3, blue: 0.7), .init(red: 0.3, green: 0.62, blue: 0.75),
             .init(red: 0.03, green: 0.05, blue: 0.16), .init(red: 0.14, green: 0.16, blue: 0.46), .init(red: 0.2, green: 0.36, blue: 0.6)],
            [.init(red: 0.12, green: 0.05, blue: 0.2), .init(red: 0.42, green: 0.12, blue: 0.42), .init(red: 0.82, green: 0.36, blue: 0.42),
             .init(red: 0.12, green: 0.08, blue: 0.36), .init(red: 0.46, green: 0.2, blue: 0.6), .init(red: 0.9, green: 0.5, blue: 0.45),
             .init(red: 0.05, green: 0.04, blue: 0.16), .init(red: 0.22, green: 0.1, blue: 0.4), .init(red: 0.5, green: 0.22, blue: 0.5)],
            [.init(red: 0.03, green: 0.1, blue: 0.14), .init(red: 0.05, green: 0.3, blue: 0.36), .init(red: 0.2, green: 0.5, blue: 0.5),
             .init(red: 0.06, green: 0.12, blue: 0.3), .init(red: 0.15, green: 0.35, blue: 0.55), .init(red: 0.36, green: 0.55, blue: 0.6),
             .init(red: 0.02, green: 0.04, blue: 0.12), .init(red: 0.08, green: 0.16, blue: 0.36), .init(red: 0.25, green: 0.3, blue: 0.5)],
        ]
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.55, 0], [1, 0],
            [0, 0.45], [0.42, 0.55], [1, 0.4],
            [0, 1], [0.6, 1], [1, 1],
        ], colors: palettes[seed % palettes.count])
        .overlay(Color.black.opacity(0.08))
    }
}

/// Rounded feature tags.
private struct FeatureChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 10) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 19, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            }
        }
    }
}

/// Wraps views onto new lines like text.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
