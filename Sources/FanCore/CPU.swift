import Foundation
import Darwin

/// Aggregate CPU utilization via the mach `host_statistics` tick counters
/// (`HOST_CPU_LOAD_INFO`). Sudoless, no IOReport dependency. Utilization is the
/// busy fraction (user+system+nice) over total ticks since the previous call.
public final class CPU {

    private var prev: host_cpu_load_info?

    public init() {}

    private func read() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    /// Busy percentage (0–100) since the previous call. Returns 0 on the very
    /// first call (no baseline yet).
    public func utilization() -> Double {
        guard let cur = read() else { return 0 }
        defer { prev = cur }
        guard let p = prev else { return 0 }

        let user = Double(cur.cpu_ticks.0) - Double(p.cpu_ticks.0)   // CPU_STATE_USER
        let sys  = Double(cur.cpu_ticks.1) - Double(p.cpu_ticks.1)   // CPU_STATE_SYSTEM
        let idle = Double(cur.cpu_ticks.2) - Double(p.cpu_ticks.2)   // CPU_STATE_IDLE
        let nice = Double(cur.cpu_ticks.3) - Double(p.cpu_ticks.3)   // CPU_STATE_NICE
        let busy = user + sys + nice
        let total = busy + idle
        guard total > 0 else { return 0 }
        return max(0, min(100, busy / total * 100))
    }
}
