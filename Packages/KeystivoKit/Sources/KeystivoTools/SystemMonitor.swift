import AppKit
import Darwin
import Foundation
import KeystivoCore
import Observation

/// One sample of system activity.
nonisolated public struct SystemSnapshot: Sendable, Equatable {
    public var cpuUsage: Double = 0
    public var perCoreUsage: [Double] = []
    public var memoryUsed: UInt64 = 0
    public var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    public var memoryPressure: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
    /// Share of the startup disk in use (0…1).
    public var diskUsedFraction: Double { diskTotal > 0 ? Double(max(diskTotal - diskFree, 0)) / Double(diskTotal) : 0 }
    public var networkDown: Double = 0
    public var networkUp: Double = 0
    public var diskFree: Int64 = 0
    public var diskTotal: Int64 = 0
    public var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    public var thermalState: ProcessInfo.ThermalState = .nominal
    // Hardware (only while a GPU or sensor display needs it).
    public var gpuUsage: Double?
    public var cpuTemperature: Double?
    public var sensors: [SensorReading] = []
    public var fans: [FanReading] = []
    public var systemPower: Double?

    public init() {}
}

/// Lightweight CPU / memory / network / disk sampling ("iStat Menus / Stats").
///
/// Sampling runs only while something displays the values (menu bar item or an
/// open panel) and stops otherwise.
@Observable
public final class SystemMonitor {
    public static let shared = SystemMonitor()

    public private(set) var snapshot = SystemSnapshot()
    public private(set) var cpuHistory: [Double] = []
    public private(set) var networkHistory: [Double] = []
    public private(set) var uploadHistory: [Double] = []
    /// Apps and processes using the most CPU / memory (only while a detail view needs them).
    public private(set) var topCPU: [ProcessUsage] = []
    public private(set) var topMemory: [ProcessUsage] = []
    /// False until two process samples exist (CPU needs a time delta).
    public private(set) var hasProcessSample = false
    /// Apps using the network right now (only while a detail view needs them).
    public private(set) var topNetwork: [NetworkUsage] = []
    public private(set) var hasNetworkSample = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var consumers = Set<String>()
    @ObservationIgnored private var previousTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    @ObservationIgnored private var previousNetwork: (down: UInt64, up: UInt64, date: Date)?
    @ObservationIgnored private let processSampler = ProcessSampler()
    /// Free disk space goes through a slow system service; it barely changes, so refresh it rarely.
    @ObservationIgnored private var disk: (free: Int64, total: Int64, date: Date)?
    @ObservationIgnored private var processConsumers = Set<String>()
    @ObservationIgnored private var processSampleCount = 0
    @ObservationIgnored private let networkSampler = NetworkUsageSampler()
    @ObservationIgnored private var networkConsumers = Set<String>()
    @ObservationIgnored private var isSamplingNetwork = false
    /// Read GPU, temperatures, fans and power too (set while such a metric is shown).
    @ObservationIgnored public var samplesHardware = false
    public private(set) var gpuHistory: [Double] = []
    public private(set) var memoryHistory: [Double] = []
    public private(set) var temperatureHistory: [Double] = []
    public var interval: TimeInterval = 2

    public init() {}

    /// Registers a consumer; sampling runs while at least one is registered.
    public func acquire(_ consumer: String) {
        consumers.insert(consumer)
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func release(_ consumer: String) {
        consumers.remove(consumer)
        processConsumers.remove(consumer)
        networkConsumers.remove(consumer)
        if networkConsumers.isEmpty {
            topNetwork = []
            hasNetworkSample = false
            networkSampleCount = 0
        }
        if processConsumers.isEmpty {
            topCPU = []
            topMemory = []
            hasProcessSample = false
            processSampleCount = 0
        }
        if consumers.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Like ``acquire(_:)``, but also ranks processes (costs a little more per sample).
    public func acquireProcesses(_ consumer: String) {
        let first = processConsumers.isEmpty
        processConsumers.insert(consumer)
        acquire(consumer)
        guard first else { return }
        sampleProcesses()
        // CPU needs two samples; take the second one quickly instead of waiting a full interval.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !self.processConsumers.isEmpty else { return }
            self.sampleProcesses()
        }
    }

    /// Like ``acquire(_:)``, but also ranks apps by network traffic.
    public func acquireNetworkProcesses(_ consumer: String) {
        let first = networkConsumers.isEmpty
        networkConsumers.insert(consumer)
        acquire(consumer)
        guard first else { return }
        sampleNetwork()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !self.networkConsumers.isEmpty else { return }
            self.sampleNetwork()
        }
    }

    private func sampleNetwork() {
        guard !isSamplingNetwork else { return }
        isSamplingNetwork = true
        let apps = Self.runningApps()
        let sampler = networkSampler
        Task.detached(priority: .utility) { [weak self] in
            let usage = sampler.sample(apps: apps)
            await MainActor.run {
                guard let self else { return }
                self.isSamplingNetwork = false
                guard !self.networkConsumers.isEmpty else { return }
                self.topNetwork = Array(usage.sorted { $0.total > $1.total }.prefix(6))
                if self.networkSampleCount > 0 { self.hasNetworkSample = true }
                self.networkSampleCount += 1
            }
        }
    }

    @ObservationIgnored private var networkSampleCount = 0

    nonisolated static func runningApps() -> [pid_t: (name: String, bundleID: String?)] {
        var apps: [pid_t: (name: String, bundleID: String?)] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            apps[app.processIdentifier] = (app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)", app.bundleIdentifier)
        }
        return apps
    }

    private func sampleProcesses() {
        let usage = processSampler.sample(apps: Self.runningApps())
        processSampleCount += 1
        hasProcessSample = processSampleCount >= 2
        topCPU = Array(usage.filter { $0.cpu >= 0.1 }.sorted { $0.cpu > $1.cpu }.prefix(5))
        topMemory = Array(usage.sorted { $0.memory > $1.memory }.prefix(5))
    }

    public func sample() {
        var next = SystemSnapshot()
        let cores = Self.cpuTicks()
        if previousTicks.count == cores.count, !cores.isEmpty {
            var perCore: [Double] = []
            var busyTotal: Double = 0, allTotal: Double = 0
            for (now, before) in zip(cores, previousTicks) {
                let busy = Double((now.user &- before.user) &+ (now.system &- before.system) &+ (now.nice &- before.nice))
                let all = busy + Double(now.idle &- before.idle)
                perCore.append(all > 0 ? busy / all : 0)
                busyTotal += busy
                allTotal += all
            }
            next.perCoreUsage = perCore
            next.cpuUsage = allTotal > 0 ? busyTotal / allTotal : 0
        }
        previousTicks = cores
        next.memoryUsed = Self.memoryUsed()
        let network = Self.networkBytes()
        let now = Date.now
        if let previous = previousNetwork {
            let seconds = max(now.timeIntervalSince(previous.date), 0.001)
            next.networkDown = Double(network.down &- previous.down) / seconds
            next.networkUp = Double(network.up &- previous.up) / seconds
        }
        previousNetwork = (network.down, network.up, now)
        if disk == nil || now.timeIntervalSince(disk!.date) > 30,
           let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            disk = (values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeTotalCapacity ?? 0), now)
        }
        next.diskFree = disk?.free ?? 0
        next.diskTotal = disk?.total ?? 0
        next.thermalState = ProcessInfo.processInfo.thermalState
        if samplesHardware {
            let sensors = HardwareSensors.shared
            next.gpuUsage = sensors.gpuUsage()
            next.sensors = sensors.temperatures()
            next.cpuTemperature = HardwareSensors.cpuTemperature(from: next.sensors)
            next.fans = sensors.fans()
            next.systemPower = sensors.systemPower()
            if let gpu = next.gpuUsage { gpuHistory = Array((gpuHistory + [gpu]).suffix(40)) }
            if let temperature = next.cpuTemperature { temperatureHistory = Array((temperatureHistory + [temperature]).suffix(40)) }
        }
        snapshot = next
        if !processConsumers.isEmpty { sampleProcesses() }
        if !networkConsumers.isEmpty { sampleNetwork() }
        cpuHistory = Array((cpuHistory + [next.cpuUsage]).suffix(40))
        memoryHistory = Array((memoryHistory + [next.memoryPressure]).suffix(40))
        networkHistory = Array((networkHistory + [next.networkDown]).suffix(40))
        uploadHistory = Array((uploadHistory + [next.networkUp]).suffix(40))
    }

    // MARK: Mach / BSD probes

    nonisolated static func cpuTicks() -> [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(cpuCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return (UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                    UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                    UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                    UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
    }

    /// "App memory + wired + compressed", matching Activity Monitor's "Memory Used".
    nonisolated static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)) &* page
    }

    nonisolated static func networkBytes() -> (down: UInt64, up: UInt64) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (0, 0) }
        defer { freeifaddrs(pointer) }
        var down: UInt64 = 0, up: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
               let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let name = String(cString: entry.ifa_name)
                // Physical Wi-Fi/Ethernet ("en*") and cellular ("pdp_ip*") only; skip VPN and bridges to avoid double counting.
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    down &+= UInt64(data.pointee.ifi_ibytes)
                    up &+= UInt64(data.pointee.ifi_obytes)
                }
            }
            cursor = entry.ifa_next
        }
        return (down, up)
    }

    /// Menu bar rate: never more than three digits, so its width is stable.
    /// "512 B", "1.0 K", "12 K", "999 K", "1.2 M", "15 M", "1.1 G".
    nonisolated public static func compactRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = max(0, bytesPerSecond.isFinite ? bytesPerSecond : 0)
        var index = 0
        while value >= 999.5, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let number = index > 0 && value < 9.95 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return "\(number) \(units[index])"
    }

    /// "1.2 MB/s" style formatting.
    nonisolated public static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }
}
