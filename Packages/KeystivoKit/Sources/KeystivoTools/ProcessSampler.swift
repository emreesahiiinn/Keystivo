import AppKit
import Darwin

/// CPU and memory of one app, including its helper processes.
nonisolated public struct ProcessUsage: Identifiable, Sendable, Equatable {
    /// The app's (or lone process's) pid.
    public let id: pid_t
    public let name: String
    public let bundleID: String?
    /// Percent of one core, like Activity Monitor (150 = one and a half cores).
    public var cpu: Double
    /// Physical memory footprint in bytes.
    public var memory: UInt64
    public var isApp: Bool { bundleID != nil }
}

/// Samples per-process CPU time and memory with `proc_pid_rusage`, grouping
/// helpers (renderers, XPC services) under the app responsible for them.
/// Only the user's own processes are readable without privileges.
nonisolated public final class ProcessSampler: @unchecked Sendable {
    private var previousTimes: [pid_t: UInt64] = [:]
    private var previousDate: UInt64 = 0
    private let lock = NSLock()

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    public init() {}

    /// Usage since the previous call, grouped by app. The first call only
    /// establishes a baseline, so CPU values are zero.
    public func sample(apps: [pid_t: (name: String, bundleID: String?)]) -> [ProcessUsage] {
        lock.lock()
        defer { lock.unlock() }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = previousDate > 0 ? Double(now - previousDate) : 0
        var times: [pid_t: UInt64] = [:]
        var groups: [pid_t: ProcessUsage] = [:]

        for pid in Self.allPIDs() where pid > 0 {
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard status == 0 else { continue }
            // rusage CPU times are Mach absolute time units on Apple Silicon.
            let cpuTime = (usage.ri_user_time &+ usage.ri_system_time) &* Self.timebase.numer / Self.timebase.denom
            times[pid] = cpuTime
            let delta = previousTimes[pid].map { cpuTime >= $0 ? cpuTime - $0 : 0 } ?? 0

            let owner = Self.owner(of: pid, apps: apps)
            var group = groups[owner] ?? ProcessUsage(
                id: owner,
                name: apps[owner]?.name ?? Self.name(of: owner),
                bundleID: apps[owner]?.bundleID,
                cpu: 0, memory: 0
            )
            if elapsed > 0 { group.cpu += Double(delta) / elapsed * 100 }
            group.memory &+= usage.ri_phys_footprint
            groups[owner] = group
        }
        previousTimes = times
        previousDate = now
        return Array(groups.values)
    }

    /// The running app a process belongs to, or the process itself.
    static func owner(of pid: pid_t, apps: [pid_t: (name: String, bundleID: String?)]) -> pid_t {
        // Helpers (e.g. "Safari Web Content") can be apps themselves; the
        // responsible app wins so their usage adds up under the app you know.
        if let responsiblePID, case let owner = responsiblePID(pid), owner > 0, owner != pid, apps[owner] != nil { return owner }
        return pid
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(count, 0))))
    }

    static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "\(pid)" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
