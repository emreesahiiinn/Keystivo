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

/// Compact CPU / memory / network readout in the menu bar.
final class SystemMonitorStatusItem {
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var metrics: [MonitorMetric] = []

    func apply(_ settings: MenuBarSettings) {
        metrics = settings.monitorMetrics
        if settings.showsMonitor { install() } else { uninstall() }
        rebuild()
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "KeystivoSystemMonitor"
        item.button?.target = self
        item.button?.action = #selector(clicked)
        self.item = item
        SystemMonitor.shared.acquire("menubar")
        rebuild()
    }

    private func uninstall() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        SystemMonitor.shared.release("menubar")
    }

    private func rebuild() {
        guard let button = item?.button else { return }
        button.subviews.forEach { $0.removeFromSuperview() }
        let hosting = NSHostingView(rootView: MonitorStatusView(metrics: metrics))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        item?.length = hosting.fittingSize.width + 4
    }

    @objc private func clicked() {
        guard let button = item?.button else { return }
        if let popover, popover.isShown { popover.performClose(nil); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SystemMonitorDetailView().localizedRoot())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
    }
}

private struct MonitorStatusView: View {
    let metrics: [MonitorMetric]

    var body: some View {
        let snapshot = SystemMonitor.shared.snapshot
        HStack(spacing: 6) {
            ForEach(metrics, id: \.self) { metric in
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

/// Detailed system monitor (also embedded in Settings and the control center).
struct SystemMonitorDetailView: View {
    var body: some View {
        let monitor = SystemMonitor.shared
        let snapshot = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            metricRow(symbol: "cpu", title: L("monitor.metric.cpu"), value: "\(Int(snapshot.cpuUsage * 100))%", fraction: snapshot.cpuUsage, color: .blue)
            Sparkline(values: monitor.cpuHistory, color: .blue).frame(height: 30)
            if !snapshot.perCoreUsage.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(snapshot.perCoreUsage.enumerated()), id: \.offset) { _, usage in
                        Capsule().fill(Color.blue.opacity(0.35 + usage * 0.65)).frame(width: 6, height: max(3, 28 * usage))
                    }
                }
                .frame(height: 28, alignment: .bottom)
            }
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
