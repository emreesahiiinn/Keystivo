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

/// CPU, memory, network and disk readouts in the menu bar, one item per metric
/// (iStat Menus-style). Each item opens the details of its own metric only.
final class SystemMonitorStatusItem: NSObject {
    private var items: [MonitorMetric: NSStatusItem] = [:]
    private var popover: NSPopover?
    private var popoverMetric: MonitorMetric?
    private var isSampling = false

    func apply(_ settings: MenuBarSettings) {
        let wanted = settings.showsMonitor ? settings.monitorMetrics : []
        for (metric, item) in items where !wanted.contains(metric) {
            NSStatusBar.system.removeStatusItem(item)
            items[metric] = nil
        }
        // New items appear to the left of existing ones, so add the last metric first.
        for metric in wanted.reversed() where items[metric] == nil { install(metric) }
        if wanted.isEmpty, isSampling {
            SystemMonitor.shared.release("menubar")
            isSampling = false
        } else if !wanted.isEmpty, !isSampling {
            SystemMonitor.shared.acquire("menubar")
            isSampling = true
        }
    }

    private func install(_ metric: MonitorMetric) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "KeystivoMonitor.\(metric.rawValue)"
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier(metric.rawValue)
        button.setAccessibilityLabel(L(metric.titleKey))
        let hosting = NSHostingView(rootView: MonitorStatusView(metric: metric))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        item.length = hosting.fittingSize.width + 4
        items[metric] = item
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let metric = MonitorMetric(rawValue: raw) else { return }
        togglePopover(metric)
    }

    /// Shows the details of `metric`; clicking the same item again closes them.
    func togglePopover(_ metric: MonitorMetric? = nil) {
        guard let metric = metric ?? MonitorMetric.allCases.first(where: { items[$0] != nil }),
              let button = items[metric]?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            if popoverMetric == metric { return }
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MetricDetailView(metric: metric).localizedRoot())
        // An active popover gets the opaque, readable material; an inactive one
        // turns see-through over bright windows.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        self.popover = popover
        popoverMetric = metric
    }
}

private struct MonitorStatusView: View {
    let metric: MonitorMetric

    var body: some View {
        let snapshot = SystemMonitor.shared.snapshot
        Group {
            switch metric {
            case .cpu: compact("cpu", "\(Int(snapshot.cpuUsage * 100))%")
            case .memory: compact("memorychip", "\(Int(snapshot.memoryPressure * 100))%")
            case .network:
                VStack(alignment: .trailing, spacing: -1) {
                    Text("↑ " + Self.short(snapshot.networkUp))
                    Text("↓ " + Self.short(snapshot.networkDown))
                }
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                // Fixed width keeps the menu bar item from jittering as values change.
                .frame(width: 52, alignment: .trailing)
            case .disk: compact("internaldrive", ByteCountFormatter.string(fromByteCount: snapshot.diskFree, countStyle: .file))
            }
        }
        .padding(.horizontal, 4)
        .fixedSize()
    }

    private func compact(_ symbol: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(minWidth: 30, alignment: .trailing)
        }
    }

    static func short(_ bytes: Double) -> String {
        switch bytes {
        case ..<1024: return "\(Int(bytes)) B"
        case ..<1_048_576: return "\(Int(bytes / 1024)) K"
        default: return String(format: "%.1f M", bytes / 1_048_576)
        }
    }
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
