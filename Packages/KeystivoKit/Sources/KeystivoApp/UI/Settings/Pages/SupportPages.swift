import AppKit
import Darwin
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
import UniformTypeIdentifiers

// MARK: - Permissions & diagnostics

struct DiagnosticsPage: View {
    let runtime: KeystivoRuntime
    @State private var levelFilter: DiagnosticLevel = .info
    @State private var stats = PerformanceStats.current()

    var body: some View {
        let diagnostics = DiagnosticsCenter.shared
        Form {
            PageHeader(symbol: "stethoscope", color: .red, titleKey: "settings.page.diagnostics", subtitleKey: "diagnostics.subtitle")
            Section(L("permissions.title")) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind)
                }
                Button(L("permissions.refresh")) { PermissionCenter.shared.refresh() }
            }
            Section(L("diagnostics.performance")) {
                LabeledContent(L("diagnostics.memory"), value: stats.memory)
                LabeledContent(L("diagnostics.cpuTime"), value: stats.cpuTime)
                LabeledContent(L("diagnostics.eventTap"), value: L(EventTapManager.shared.isRunning ? "common.on" : "common.off"))
                LabeledContent(L("diagnostics.trackpadEngine"), value: L(TrackpadGestureEngine.shared.isRunning ? "common.on" : "common.off"))
                LabeledContent(L("diagnostics.audioTaps"), value: "\(AppAudioController.shared.settings.count)")
                LabeledContent(L("diagnostics.clipboard"), value: L(runtime.config.clipboard.isEnabled && !ClipboardMonitor.shared.isPaused ? "common.on" : "common.off"))
                Text(L("diagnostics.performanceFooter")).font(.caption).foregroundStyle(.secondary)
            }
            let conflicts = ConflictReport.make(runtime: runtime).filter { $0.severity != .override }
            Section(L("diagnostics.conflicts", conflicts.count)) {
                if conflicts.isEmpty {
                    Label(L("gesturesSettings.noConflicts"), systemImage: "checkmark.seal").foregroundStyle(.green)
                }
                ForEach(conflicts.prefix(20)) { ConflictRow(conflict: $0) }
            }
            Section {
                Picker(L("diagnostics.level"), selection: $levelFilter) {
                    ForEach(DiagnosticLevel.allCases, id: \.self) { Text(L("diagnostics.level.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented)
                let entries = diagnostics.entries.filter { $0.level >= levelFilter }
                if entries.isEmpty { Text(L("diagnostics.empty")).foregroundStyle(.secondary) }
                ForEach(entries.prefix(150)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.level.symbolName)
                            .foregroundStyle(entry.level == .error ? .red : (entry.level == .warning ? .orange : .secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message).font(.callout).textSelection(.enabled)
                            if let detail = entry.detail { Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                            Text("\(entry.module) · \(entry.date.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                HStack {
                    Button(L("diagnostics.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.exportText(), forType: .string)
                    }
                    Button(L("diagnostics.clear"), role: .destructive) { diagnostics.clear() }
                }
            } header: {
                Text(L("diagnostics.log"))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            diagnostics.markSeen()
            PermissionCenter.shared.refresh()
            PermissionCenter.shared.startWatching(duration: 30)
        }
        .task {
            while !Task.isCancelled {
                stats = PerformanceStats.current()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct PermissionRow: View {
    let kind: PermissionKind

    var body: some View {
        let status = PermissionCenter.shared.status(kind)
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(symbol: kind.symbolName, color: status == .granted ? .green : (kind.isEssential ? .orange : .gray), size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(L(kind.titleKey)).font(.callout.weight(.semibold))
                    if kind.isEssential { Badge(text: L("permissions.required"), color: .orange) }
                }
                Text(L(kind.reasonKey)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if status != .granted, PermissionCenter.isAdHocSigned, kind == .accessibility || kind == .screenRecording {
                    Label(L("permissions.staleEntryHint"), systemImage: "lightbulb")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                PermissionBadge(kind: kind)
                if status != .granted {
                    Button(L("permissions.grant")) { PermissionCenter.shared.request(kind) }
                        .controlSize(.small)
                } else {
                    Button(L("permissions.open")) { PermissionCenter.shared.openSettings(kind) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Lightweight self-measurement for the "low CPU, memory and battery" goal.
struct PerformanceStats {
    let memory: String
    let cpuTime: String

    static func current() -> PerformanceStats {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        let memory = result == KERN_SUCCESS ? ByteCountFormatter.string(fromByteCount: Int64(info.phys_footprint), countStyle: .memory) : "—"
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return PerformanceStats(memory: memory, cpuTime: String(format: "%.1f s", seconds))
    }
}

// MARK: - Backup / import / export

struct BackupPage: View {
    let runtime: KeystivoRuntime
    @State private var selectedSections = Set(KeystivoConfiguration.Section.allCases)
    @State private var pendingImport: ConfigurationStore.ExportFile?
    @State private var importSections = Set<KeystivoConfiguration.Section>()
    @State private var message: String?
    @State private var confirmReset = false

    var body: some View {
        Form {
            PageHeader(symbol: "arrow.up.arrow.down.square.fill", color: .green, titleKey: "settings.page.backup", subtitleKey: "backup.subtitle")
            Section(L("backup.export")) {
                sectionGrid(selection: $selectedSections, available: Set(KeystivoConfiguration.Section.allCases))
                Button(L("backup.exportButton")) { exportConfiguration() }
                    .disabled(selectedSections.isEmpty)
            }
            Section(L("backup.import")) {
                if let pending = pendingImport {
                    Text(L("backup.importFrom", pending.appVersion, pending.exportedAt.formatted())).font(.caption)
                    sectionGrid(selection: $importSections, available: Set(pending.sections.compactMap(KeystivoConfiguration.Section.init(rawValue:))))
                    HStack {
                        Button(L("common.cancel")) { pendingImport = nil }
                        Button(L("backup.apply")) {
                            runtime.store.apply(pending, sections: importSections)
                            pendingImport = nil
                            message = L("backup.imported")
                        }
                        .disabled(importSections.isEmpty)
                    }
                } else {
                    Button(L("backup.chooseFile")) { chooseImport() }
                }
            }
            Section(L("backup.backups")) {
                Button(L("backup.createNow")) {
                    if runtime.store.backup(reason: "manual") != nil { message = L("backup.created") }
                }
                ForEach(runtime.store.backups.prefix(10), id: \.self) { url in
                    HStack {
                        Text(url.deletingPathExtension().lastPathComponent).font(.caption.monospaced())
                        Spacer()
                        Button(L("backup.restore")) {
                            do {
                                try runtime.store.restore(backup: url)
                                message = L("backup.restored")
                            } catch {
                                message = error.localizedDescription
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button(L("backup.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.backupsDirectory]) }
            }
            Section {
                Button(L("general.reset"), role: .destructive) { confirmReset = true }
            }
            if let message { Section { Label(message, systemImage: "info.circle") } }
        }
        .formStyle(.grouped)
        .confirmationDialog(L("general.reset.confirm"), isPresented: $confirmReset) {
            Button(L("general.reset"), role: .destructive) { runtime.store.resetToDefaults() }
        } message: { Text(L("general.reset.message")) }
    }

    private func sectionGrid(selection: Binding<Set<KeystivoConfiguration.Section>>, available: Set<KeystivoConfiguration.Section>) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(KeystivoConfiguration.Section.allCases.filter(available.contains)) { section in
                Toggle(L(section.titleKey), isOn: Binding(
                    get: { selection.wrappedValue.contains(section) },
                    set: { if $0 { selection.wrappedValue.insert(section) } else { selection.wrappedValue.remove(section) } }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Keystivo-\(formatter.string(from: .now)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try runtime.store.export(sections: selectedSections).write(to: url, options: .atomic)
            message = L("backup.exported", url.lastPathComponent)
        } catch {
            message = error.localizedDescription
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try runtime.store.previewImport(try Data(contentsOf: url))
            pendingImport = file
            importSections = Set(file.sections.compactMap(KeystivoConfiguration.Section.init(rawValue:)))
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - About

struct AboutPage: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: .accentColor.opacity(0.4), radius: 24, y: 8)
            Text("Keystivo").font(.largeTitle.weight(.bold))
            Text(L("about.version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                   Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))
                .foregroundStyle(.secondary)
            Text(L("about.tagline"))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["about.principle.keyboard", "about.principle.private", "about.principle.efficient", "about.principle.modular"], id: \.self) { key in
                    Label(L(key), systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.top, 8)
            Spacer()
            Text(L("about.copyright")).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
