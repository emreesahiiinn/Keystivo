import Darwin
import Foundation

/// Network traffic of one app (including its helpers), in bytes per second.
nonisolated public struct NetworkUsage: Identifiable, Sendable, Equatable {
    public let id: pid_t
    public let name: String
    public let bundleID: String?
    public var down: Double
    public var up: Double
    public var total: Double { down + up }
}

/// Per-process network traffic from the system's network statistics, read with
/// `nettop` (the data Activity Monitor's Network tab shows; no privileges
/// needed). Each sample is one cheap snapshot of cumulative byte counters;
/// rates come from the difference between consecutive snapshots.
nonisolated public final class NetworkUsageSampler: @unchecked Sendable {
    private var previous: [pid_t: (down: UInt64, up: UInt64)] = [:]
    private var previousDate: UInt64 = 0
    private let lock = NSLock()

    public init() {}

    /// Rates since the previous call, grouped by app. The first call returns
    /// nothing (it only records the baseline).
    public func sample(apps: [pid_t: (name: String, bundleID: String?)]) -> [NetworkUsage] {
        guard let output = Self.snapshot() else { return [] }
        let counters = Self.parse(output)
        lock.lock()
        defer { lock.unlock() }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let seconds = previousDate > 0 ? Double(now - previousDate) / 1_000_000_000 : 0
        defer {
            previous = counters.mapValues { ($0.down, $0.up) }
            previousDate = now
        }
        guard seconds > 0 else { return [] }

        var groups: [pid_t: NetworkUsage] = [:]
        for (pid, counter) in counters {
            guard let before = previous[pid] else { continue }
            let down = counter.down >= before.down ? Double(counter.down - before.down) / seconds : 0
            let up = counter.up >= before.up ? Double(counter.up - before.up) / seconds : 0
            guard down + up > 0 else { continue }
            let owner = ProcessSampler.owner(of: pid, apps: apps)
            var group = groups[owner] ?? NetworkUsage(
                id: owner,
                name: apps[owner]?.name ?? (owner == pid ? counter.name : ProcessSampler.name(of: owner)),
                bundleID: apps[owner]?.bundleID,
                down: 0, up: 0
            )
            group.down += down
            group.up += up
            groups[owner] = group
        }
        return Array(groups.values)
    }

    /// Parses `nettop -P -x -J bytes_in,bytes_out` CSV ("name.pid,in,out,").
    static func parse(_ output: String) -> [pid_t: (name: String, down: UInt64, up: UInt64)] {
        var result: [pid_t: (name: String, down: UInt64, up: UInt64)] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let down = UInt64(fields[1]), let up = UInt64(fields[2]) else { continue }
            result[pid] = (String(fields[0][..<dot]), down, up)
        }
        return result
    }

    /// One snapshot of every process's cumulative traffic (~10 ms).
    static func snapshot() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // External interfaces only: localhost traffic between dev servers never
        // leaves the Mac and isn't part of the totals shown above the list.
        process.arguments = ["-P", "-L", "1", "-x", "-n", "-t", "external", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
