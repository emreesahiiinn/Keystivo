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
    public var networkDown: Double = 0
    public var networkUp: Double = 0
    public var diskFree: Int64 = 0
    public var diskTotal: Int64 = 0
    public var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    public var thermalState: ProcessInfo.ThermalState = .nominal

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

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var consumers = Set<String>()
    @ObservationIgnored private var previousTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    @ObservationIgnored private var previousNetwork: (down: UInt64, up: UInt64, date: Date)?
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
        if consumers.isEmpty {
            timer?.invalidate()
            timer = nil
        }
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
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            next.diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            next.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        }
        next.thermalState = ProcessInfo.processInfo.thermalState
        snapshot = next
        cpuHistory = Array((cpuHistory + [next.cpuUsage]).suffix(40))
        networkHistory = Array((networkHistory + [next.networkDown]).suffix(40))
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

    /// "1.2 MB/s" style formatting.
    nonisolated public static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }
}
