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

/// Hides menu bar icons behind a collapsible separator (Bartender / Hidden Bar style).
///
/// Two status items are added: a visible chevron and an invisible separator to
/// its left. ⌘-drag icons to the left of the separator to hide them. Collapsing
/// expands the separator so the icons left of it are pushed off-screen — no
/// private APIs and no screen recording needed.
final class MenuBarManager {
    private var toggleItem: NSStatusItem?
    private var separatorItem: NSStatusItem?
    private var isCollapsed = false
    private var collapseTask: Task<Void, Never>?
    private var autoCollapseSeconds = 10
    private static let collapsedLength: CGFloat = 10_000
    private static let separatorLength: CGFloat = 8

    func apply(_ settings: MenuBarSettings) {
        autoCollapseSeconds = settings.autoCollapseSeconds
        if settings.managerEnabled { install() } else { uninstall() }
    }

    private func install() {
        guard toggleItem == nil else { return }
        // Created right-to-left: the chevron sits right of the separator.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = "KeystivoMenuBarToggle"
        toggle.button?.image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: L("menubar.toggle"))
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        toggle.button?.toolTip = L("menubar.toggleTip")
        let separator = NSStatusBar.system.statusItem(withLength: Self.separatorLength)
        separator.autosaveName = "KeystivoMenuBarSeparator"
        separator.button?.image = NSImage(systemSymbolName: "poweron", accessibilityDescription: L("menubar.separator"))
        separator.button?.imageScaling = .scaleProportionallyDown
        separator.button?.alphaValue = 0.35
        toggleItem = toggle
        separatorItem = separator
        collapse()
    }

    private func uninstall() {
        collapseTask?.cancel()
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        if let separatorItem { NSStatusBar.system.removeStatusItem(separatorItem) }
        toggleItem = nil
        separatorItem = nil
    }

    @objc private func toggleClicked() {
        isCollapsed ? expand() : collapse()
    }

    func toggle() {
        guard toggleItem != nil else { return }
        toggleClicked()
    }

    private func expand() {
        isCollapsed = false
        separatorItem?.length = Self.separatorLength
        separatorItem?.button?.alphaValue = 0.35
        toggleItem?.button?.image = NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: L("menubar.toggle"))
        collapseTask?.cancel()
        guard autoCollapseSeconds > 0 else { return }
        let seconds = autoCollapseSeconds
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.collapse()
        }
    }

    private func collapse() {
        isCollapsed = true
        separatorItem?.length = Self.collapsedLength
        separatorItem?.button?.alphaValue = 0
        toggleItem?.button?.image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: L("menubar.toggle"))
    }
}

/// CPU, memory, network and disk readouts as one compact menu bar item, so
/// other icons can't end up between them. Each metric is its own view inside
/// the item, and clicking a metric opens the details of that metric only.
final class SystemMonitorStatusItem: NSObject {
    private var item: NSStatusItem?
    private var stack: NSStackView?
    private var popover: NSPopover?
    private var popoverMetric: MonitorMetric?
    private var metrics: [MonitorMetric] = []

    func apply(_ settings: MenuBarSettings) {
        let wanted = settings.showsMonitor ? settings.monitorMetrics : []
        guard wanted != metrics || (item == nil) != wanted.isEmpty else { return }
        metrics = wanted
        if wanted.isEmpty { uninstall() } else { install() }
    }

    private func install() {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "KeystivoSystemMonitor"
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            self.item = item
            SystemMonitor.shared.acquire("menubar")
        }
        guard let item, let button = item.button else { return }
        button.subviews.forEach { $0.removeFromSuperview() }
        button.setAccessibilityLabel(metrics.map { L($0.titleKey) }.joined(separator: ", "))

        let stack = PassthroughStackView()
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        for metric in metrics {
            let segment = NSHostingView(rootView: MonitorSegmentView(metric: metric) { [weak self] in self?.updateLength() })
            segment.identifier = NSUserInterfaceItemIdentifier(metric.rawValue)
            stack.addArrangedSubview(segment)
        }
        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            stack.topAnchor.constraint(equalTo: button.topAnchor),
            stack.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        self.stack = stack
        updateLength()
    }

    /// Values change width (e.g. free disk space); keep the item exactly as wide as its content.
    private func updateLength() {
        guard let item, let stack else { return }
        let width = ceil(stack.fittingSize.width)
        if abs(item.length - width) > 0.5 { item.length = width }
    }

    private func uninstall() {
        popover?.performClose(nil)
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        stack = nil
        SystemMonitor.shared.release("menubar")
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let window = sender.window else { return }
        // The pointer itself, not the current event: robust for status bar clicks.
        let point = sender.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        togglePopover(metric(atX: point.x, in: sender))
    }

    /// The metric whose segment is nearest to `x` (button coordinates).
    func metric(atX x: CGFloat, in button: NSView) -> MonitorMetric? {
        guard let stack else { return metrics.first }
        let segments: [(MonitorMetric, CGRect)] = stack.arrangedSubviews.compactMap { view in
            guard let raw = view.identifier?.rawValue, let metric = MonitorMetric(rawValue: raw) else { return nil }
            return (metric, view.convert(view.bounds, to: button))
        }
        if let hit = segments.first(where: { $0.1.minX - 3.5 <= x && x <= $0.1.maxX + 3.5 }) { return hit.0 }
        return segments.min { abs($0.1.midX - x) < abs($1.1.midX - x) }?.0 ?? metrics.first
    }

    private func segmentFrame(_ metric: MonitorMetric, in button: NSView) -> CGRect? {
        guard let view = stack?.arrangedSubviews.first(where: { $0.identifier?.rawValue == metric.rawValue }) else { return nil }
        return view.convert(view.bounds, to: button)
    }

    /// Shows the details of `metric` below its segment; clicking the same segment again closes them.
    func togglePopover(_ metric: MonitorMetric? = nil) {
        guard let metric = metric ?? metrics.first, let button = item?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            if popoverMetric == metric { return }
        }
        let segment = segmentFrame(metric, in: button) ?? button.bounds
        let anchor = CGRect(x: segment.minX, y: 0, width: segment.width, height: button.bounds.height)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MetricDetailView(metric: metric).localizedRoot())
        // An active popover gets the opaque, readable material; an inactive one
        // turns see-through over bright windows.
        NSApp.activate()
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        self.popover = popover
        popoverMetric = metric
    }

    #if DEBUG
    /// Self-check: clicking the middle of each segment must pick that segment.
    func verifyHitTesting() -> [String] {
        guard let button = item?.button, let window = button.window else { return ["no item"] }
        return metrics.compactMap { metric in
            guard let frame = segmentFrame(metric, in: button) else { return "\(metric.rawValue): no frame" }
            let screen = window.convertPoint(toScreen: button.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil))
            let back = button.convert(window.convertPoint(fromScreen: screen), from: nil)
            let hit = self.metric(atX: back.x, in: button)
            return "\(metric.rawValue) [\(Int(frame.minX))–\(Int(frame.maxX))] → \(hit?.rawValue ?? "nil")"
        }
    }
    #endif
}

/// Lets every click inside the item reach the status bar button.
private final class PassthroughStackView: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct MonitorSegmentView: View {
    let metric: MonitorMetric
    let onWidthChange: () -> Void

    var body: some View {
        let snapshot = SystemMonitor.shared.snapshot
        content(snapshot)
            .fixedSize()
            .frame(maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { _ in onWidthChange() }
    }

    @ViewBuilder
    private func content(_ snapshot: SystemSnapshot) -> some View {
        switch metric {
        case .cpu: compact("cpu", "\(Int(snapshot.cpuUsage * 100))%", width: 27)
        case .memory: compact("memorychip", "\(Int(snapshot.memoryPressure * 100))%", width: 27)
        case .network:
            VStack(alignment: .trailing, spacing: -1) {
                Text("↑ " + SystemMonitor.compactRate(snapshot.networkUp)).lineLimit(1)
                Text("↓ " + SystemMonitor.compactRate(snapshot.networkDown)).lineLimit(1)
            }
            .font(.system(size: 8.5, weight: .medium).monospacedDigit())
            .fixedSize()
            // Wide enough for the widest possible value, so it never wraps or jitters.
            .frame(width: Self.networkWidth, alignment: .trailing)
        case .disk: compact("internaldrive", ByteCountFormatter.string(fromByteCount: snapshot.diskFree, countStyle: .file), width: nil)
        }
    }

    private func compact(_ symbol: String, _ value: String, width: CGFloat?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(minWidth: width, alignment: .trailing)
        }
    }

    static let networkWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        let widest = ["↓ 999 B", "↓ 999 K", "↓ 9.9 M", "↓ 999 M", "↓ 9.9 G"].map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 40
        return ceil(widest) + 1
    }()
}

/// The popover of one menu bar metric.
struct MetricDetailView: View {
    let metric: MonitorMetric
    @Environment(\.colorScheme) private var colorScheme

    private var consumer: String { "detail.\(metric.rawValue)" }

    var body: some View {
        let monitor = SystemMonitor.shared
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            switch metric {
            case .cpu:
                header("cpu", L("monitor.metric.cpu"), "\(Int(snapshot.cpuUsage * 100))%")
                ProgressView(value: min(max(snapshot.cpuUsage, 0), 1)).tint(.blue)
                Sparkline(values: monitor.cpuHistory, color: .blue).frame(height: 40)
                CoreBars(usage: snapshot.perCoreUsage)
                ProcessList(title: L("monitor.topCPU"), items: monitor.topCPU,
                            placeholder: monitor.hasProcessSample ? L("monitor.idle") : L("monitor.measuring")) { String(format: "%.1f%%", $0.cpu) }
                activityMonitorLink
            case .memory:
                header("memorychip", L("monitor.metric.memory"),
                       "\(ByteCountFormatter.string(fromByteCount: Int64(snapshot.memoryUsed), countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.memoryTotal), countStyle: .memory))")
                ProgressView(value: min(max(snapshot.memoryPressure, 0), 1)).tint(.purple)
                ProcessList(title: L("monitor.topMemory"), items: monitor.topMemory, placeholder: L("monitor.measuring")) {
                    ByteCountFormatter.string(fromByteCount: Int64($0.memory), countStyle: .memory)
                }
                activityMonitorLink
            case .network:
                header("network", L("monitor.metric.network"), "")
                HStack(spacing: 10) {
                    rate(L("monitor.download"), "arrow.down", snapshot.networkDown, .green)
                    rate(L("monitor.upload"), "arrow.up", snapshot.networkUp, .orange)
                }
                ZStack {
                    Sparkline(values: monitor.networkHistory, color: .green)
                    Sparkline(values: monitor.uploadHistory, color: .orange)
                }
                .frame(height: 44)
                NetworkList(items: monitor.topNetwork, placeholder: monitor.hasNetworkSample ? L("monitor.networkQuiet") : L("monitor.measuring"))
                activityMonitorLink
            case .disk:
                let used = max(snapshot.diskTotal - snapshot.diskFree, 0)
                header("internaldrive", L("monitor.metric.disk"), L("monitor.diskFree", ByteCountFormatter.string(fromByteCount: snapshot.diskFree, countStyle: .file)))
                ProgressView(value: snapshot.diskTotal > 0 ? Double(used) / Double(snapshot.diskTotal) : 0).tint(.orange)
                HStack {
                    Text(L("monitor.used", ByteCountFormatter.string(fromByteCount: used, countStyle: .file)))
                    Spacer()
                    Text(L("monitor.capacity", ByteCountFormatter.string(fromByteCount: snapshot.diskTotal, countStyle: .file)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: metric == .network ? 380 : 320)
        .background {
            // Solid backing so the text stays readable over bright windows.
            Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.82 : 0.9)
                .ignoresSafeArea()
        }
        .onAppear {
            if metric == .cpu || metric == .memory {
                SystemMonitor.shared.acquireProcesses(consumer)
            } else if metric == .network {
                SystemMonitor.shared.acquireNetworkProcesses(consumer)
            } else {
                SystemMonitor.shared.acquire(consumer)
            }
        }
        .onDisappear { SystemMonitor.shared.release(consumer) }
    }

    private func header(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.headline)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func rate(_ title: String, _ symbol: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(SystemMonitor.rate(value)).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var activityMonitorLink: some View {
        Button(L("monitor.openActivityMonitor")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
        .buttonStyle(.link)
        .font(.caption)
    }
}

private struct CoreBars: View {
    let usage: [Double]

    var body: some View {
        if !usage.isEmpty {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(usage.enumerated()), id: \.offset) { _, value in
                    Capsule().fill(Color.blue.opacity(0.35 + value * 0.65)).frame(width: 6, height: max(3, 28 * value))
                }
            }
            .frame(height: 28, alignment: .bottom)
        }
    }
}

/// Apps using the network, with download and upload rates.
private struct NetworkList: View {
    let items: [NetworkUsage]
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("monitor.topNetwork")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text(placeholder).font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(items) { usage in
                    HStack(spacing: 8) {
                        if let bundleID = usage.bundleID {
                            AppIconView(bundleID: bundleID, size: 16)
                        } else {
                            Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16, height: 16)
                        }
                        Text(usage.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text("↓ " + SystemMonitor.rate(usage.down)).foregroundStyle(.green)
                            .frame(minWidth: 70, alignment: .trailing)
                        Text("↑ " + SystemMonitor.rate(usage.up)).foregroundStyle(.orange)
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(.snappy(duration: 0.25), value: items.map(\.id))
    }
}

/// Top apps by CPU or memory; right-click to quit one.
private struct ProcessList: View {
    let title: String
    let items: [ProcessUsage]
    let placeholder: String
    let value: (ProcessUsage) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text(placeholder).font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(items) { usage in
                    ProcessRow(usage: usage, value: value(usage))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Detailed system monitor (embedded in Settings and the control center).
struct SystemMonitorDetailView: View {
    var body: some View {
        let monitor = SystemMonitor.shared
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            metricRow(symbol: "cpu", title: L("monitor.metric.cpu"), value: "\(Int(snapshot.cpuUsage * 100))%", fraction: snapshot.cpuUsage, color: .blue)
            Sparkline(values: monitor.cpuHistory, color: .blue).frame(height: 30)
            CoreBars(usage: snapshot.perCoreUsage)
            metricRow(symbol: "memorychip", title: L("monitor.metric.memory"),
                      value: "\(ByteCountFormatter.string(fromByteCount: Int64(snapshot.memoryUsed), countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: Int64(snapshot.memoryTotal), countStyle: .memory))",
                      fraction: snapshot.memoryPressure, color: .purple)
            metricRow(symbol: "network", title: L("monitor.metric.network"),
                      value: "↓ \(SystemMonitor.rate(snapshot.networkDown))  ↑ \(SystemMonitor.rate(snapshot.networkUp))", fraction: nil, color: .green)
            Sparkline(values: monitor.networkHistory, color: .green).frame(height: 24)
            let used = snapshot.diskTotal > 0 ? 1 - Double(snapshot.diskFree) / Double(snapshot.diskTotal) : 0
            metricRow(symbol: "internaldrive", title: L("monitor.metric.disk"),
                      value: L("monitor.diskFree", ByteCountFormatter.string(fromByteCount: snapshot.diskFree, countStyle: .file)), fraction: used, color: .orange)
            HStack {
                Label(L("monitor.uptime"), systemImage: "clock")
                Spacer()
                Text(Duration.seconds(snapshot.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { SystemMonitor.shared.acquire("detail") }
        .onDisappear { SystemMonitor.shared.release("detail") }
    }

    private func metricRow(symbol: String, title: String, value: String, fraction: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol).font(.callout.weight(.medium))
                Spacer()
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1)).tint(color)
            }
        }
    }
}

private struct ProcessRow: View {
    let usage: ProcessUsage
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            if let bundleID = usage.bundleID {
                AppIconView(bundleID: bundleID, size: 16)
            } else {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            Text(usage.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let app = NSRunningApplication(processIdentifier: usage.id) {
                Button(L("monitor.quit")) { app.terminate() }
                Button(L("monitor.forceQuit")) { app.forceTerminate() }
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(values.max() ?? 1, 0.0001)
            let points = values.enumerated().map { index, value in
                CGPoint(x: proxy.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)),
                        y: proxy.size.height * (1 - CGFloat(value / maxValue)))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: proxy.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: proxy.size.height))
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .animation(.easeOut(duration: 0.3), value: values)
        }
    }
}
