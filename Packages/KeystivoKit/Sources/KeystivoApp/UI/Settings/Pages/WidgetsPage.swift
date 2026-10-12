import AppKit
import KeystivoCore
import SwiftUI

/// Settings › Widgets: a live gallery to add from, and the added widgets with their options.
struct WidgetsPage: View {
    @Bindable var runtime: KeystivoRuntime

    private var widgets: Binding<WidgetSettings> { $runtime.config.widgets }

    var body: some View {
        Form {
            PageHeader(symbol: "square.grid.2x2.fill", color: .orange, titleKey: "settings.page.widgets", subtitleKey: "widgets.subtitle")
            Section {
                Toggle(L("widgets.showDesktop"), isOn: widgets.showsDesktopWidgets)
                Picker(L("widgets.layer"), selection: widgets.alwaysOnTop) {
                    Text(L("widgets.layer.desktop")).tag(false)
                    Text(L("widgets.layer.top")).tag(true)
                }
                .pickerStyle(.segmented)
                Picker(L("cc.settings.background"), selection: widgets.background) {
                    ForEach(PanelBackground.allCases, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(L("action.widgets.toggleDesktop")) { ActionShortcutField(runtime: runtime, actionID: "widgets.toggleDesktop") }
            } header: {
                Text(L("widgets.general"))
            } footer: {
                Text(L("widgets.generalFooter")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("widgets.added")) {
                if runtime.config.widgets.instances.isEmpty {
                    Text(L("widgets.none")).foregroundStyle(.secondary)
                }
                ForEach($runtime.config.widgets.instances) { $instance in
                    WidgetInstanceRow(runtime: runtime, instance: $instance)
                }
            }
            Section(L("widgets.gallery")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 14)], spacing: 16) {
                    ForEach(WidgetKind.allCases) { kind in
                        GalleryCard(runtime: runtime, kind: kind)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
    }
}

/// A widget kind with a live preview and add buttons.
private struct GalleryCard: View {
    let runtime: KeystivoRuntime
    let kind: WidgetKind
    @State private var sample: WidgetInstance

    init(runtime: KeystivoRuntime, kind: WidgetKind) {
        self.runtime = runtime
        self.kind = kind
        _sample = State(initialValue: WidgetInstance(kind: kind, size: kind.sizes.contains(.medium) ? .medium : kind.defaultSize))
    }

    private let previewScale: CGFloat = 0.64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35))
                WidgetView(runtime: runtime, instance: sample)
                    .padding(14)
                    .frame(width: sample.size.points.width, height: sample.size.points.height)
                    .panelSurface(.glass, cornerRadius: 22)
                    .environment(\.colorScheme, .dark)
                    .scaleEffect(previewScale)
                    .frame(width: sample.size.points.width * previewScale, height: sample.size.points.height * previewScale)
                    .allowsHitTesting(false)
            }
            .frame(height: 344 * previewScale * 0.5 + 40)
            VStack(alignment: .leading, spacing: 2) {
                Label(L(kind.titleKey), systemImage: kind.symbol).font(.callout.weight(.medium))
                Text(L(kind.helpKey)).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            HStack(spacing: 6) {
                Button(L("widgets.addDesktop")) { runtime.addWidget(kind, placement: .desktop) }
                Button(L("widgets.addPanel")) { runtime.addWidget(kind, placement: .panel) }
            }
            .controlSize(.small)
        }
    }
}

/// An added widget: kind, size, place and its options.
private struct WidgetInstanceRow: View {
    let runtime: KeystivoRuntime
    @Binding var instance: WidgetInstance
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            options
                .padding(.top, 4)
        } label: {
            HStack(spacing: 10) {
                SymbolTile(symbol: instance.kind.symbol, color: .orange, size: 24)
                Text(L(instance.kind.titleKey))
                Spacer()
                Picker("", selection: Binding(get: { instance.size }, set: { instance.size = $0; instance.origin = nil })) {
                    ForEach(instance.kind.sizes, id: \.self) { Text(L($0.titleKey)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: Binding(get: { instance.placement }, set: { runtime.moveWidget(instance.id, to: $0) })) {
                    Text(L("widgets.place.desktop")).tag(WidgetPlacement.desktop)
                    Text(L("widgets.place.panel")).tag(WidgetPlacement.panel)
                }
                .labelsHidden()
                .fixedSize()
                Button { runtime.removeWidget(instance.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L("widgets.remove"))
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        switch instance.kind {
        case .clock:
            Toggle(L("widgets.option.seconds"), isOn: $instance.showsSeconds)
        case .worldClock:
            TimeZoneListEditor(zones: $instance.timeZones)
        case .weather:
            LabeledContent(L("widgets.option.city")) {
                TextField(WeatherService.defaultCity, text: $instance.city)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            Text(L("widgets.option.cityHelp")).font(.caption).foregroundStyle(.secondary)
        case .shortcuts:
            ActionIDListEditor(actions: $instance.actions)
        case .countdown:
            LabeledContent(L("widgets.option.title")) {
                TextField(L("widget.kind.countdown"), text: $instance.title).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            DatePicker(L("widgets.option.date"), selection: Binding(get: { instance.targetDate ?? .now }, set: { instance.targetDate = $0 }), displayedComponents: [.date, .hourAndMinute])
        case .timer:
            Stepper(L("widgets.option.minutes", instance.timerMinutes), value: $instance.timerMinutes, in: 1...180)
        case .calendar, .system, .battery, .notes, .clipboard:
            Text(L("widgets.option.none")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// World clock cities: remove, reorder, add by region.
private struct TimeZoneListEditor: View {
    @Binding var zones: [String]

    private static let regions: [(String, [String])] = {
        let grouped = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") }) { String($0.split(separator: "/")[0]) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted()) }
    }()

    var body: some View {
        ForEach(Array(zones.enumerated()), id: \.element) { index, identifier in
            HStack {
                Text(identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier)
                Text(identifier).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { if index > 0 { zones.swapAt(index, index - 1) } } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { zones.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .help(L("common.remove"))
            }
            .buttonStyle(.borderless)
        }
        Menu {
            ForEach(Self.regions, id: \.0) { region, identifiers in
                Menu(region) {
                    ForEach(identifiers, id: \.self) { identifier in
                        Button(identifier.split(separator: "/").dropFirst().joined(separator: " / ").replacingOccurrences(of: "_", with: " ")) {
                            if !zones.contains(identifier) { zones.append(identifier) }
                        }
                    }
                }
            }
        } label: {
            Label(L("widgets.option.addCity"), systemImage: "plus")
        }
        .fixedSize()
    }
}
