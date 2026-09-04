#if canImport(Darwin)
import Darwin
import Foundation

/// Reads the live process table through `libproc`.
///
/// We deliberately avoid the `kinfo_proc` sysctl path: its `p_starttime`
/// lives inside an anonymous union that Swift imports inconsistently across
/// SDKs. `proc_pidinfo` gives us the same facts through a stable struct.
public struct DarwinProcessSource: ProcessSource {

    /// `KERN_ARGMAX`, read once. It is a boot-time constant — around 1 MB —
    /// and asking the kernel for it once per process was the single most
    /// expensive thing in the old scan path.
    private static let argMax: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else {
            return 256 * 1024
        }
        return Int(value)
    }()

    public init() {}

    public func snapshot() -> [ProcessSnapshot] {
        let me = getuid()
        let pids = allPIDs()

        // One ~1 MB buffer for the whole scan, reused for every process.
        // Allocating it per process meant hundreds of megabytes of churn every
        // few seconds — in an app whose entire purpose is reclaiming memory.
        var argv = [UInt8](repeating: 0, count: Self.argMax)

        var result: [ProcessSnapshot] = []
        result.reserveCapacity(pids.count / 2)

        for pid in pids {
            guard let bsd = bsdInfo(pid) else { continue }
            // Other users' processes are not ours to touch, and we can't read
            // their argv anyway. Filtering here also skips the argv read.
            guard bsd.pbi_uid == me else { continue }

            let started = Date(
                timeIntervalSince1970:
                    Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000
            )
            let usage = resourceUsage(pid)

            result.append(
                ProcessSnapshot(
                    pid: pid,
                    parentPID: pid_t(bsd.pbi_ppid),
                    userID: bsd.pbi_uid,
                    name: withUnsafeBytes(of: bsd.pbi_name) { Self.cString(from: $0) },
                    arguments: arguments(of: pid, into: &argv),
                    startedAt: started,
                    residentBytes: usage.resident,
                    cpuNanoseconds: usage.cpu
                )
            )
        }
        return result
    }

    // MARK: - libproc

    private func allPIDs() -> [pid_t] {
        // Ask for the size, then read. The table can grow between the two
        // calls, so over-allocate rather than loop.
        let probe = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probe > 0 else { return [] }

        let capacity = Int(probe) / MemoryLayout<pid_t>.size + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0,
            &buffer, Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard written > 0 else { return [] }

        let count = Int(written) / MemoryLayout<pid_t>.size
        return buffer.prefix(count).filter { $0 > 0 }
    }

    private func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return read == size ? info : nil
    }

    /// Resident memory and cumulative CPU time, from one syscall.
    ///
    /// `pti_total_user` and `pti_total_system` are cumulative nanoseconds. A
    /// single reading says nothing useful — the scanner differences two of
    /// them to get a rate, which is what "spinning at 100%" actually means.
    private func resourceUsage(_ pid: pid_t) -> (resident: UInt64, cpu: UInt64) {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return (0, 0) }
        return (info.pti_resident_size, info.pti_total_user &+ info.pti_total_system)
    }

    private static func cString(from raw: UnsafeRawBufferPointer) -> String {
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    // MARK: - argv

    /// Full command line via `KERN_PROCARGS2`, into a caller-owned buffer.
    ///
    /// Layout: `argc` (Int32) → exec path (NUL-terminated) → NUL padding →
    /// argc NUL-terminated argv strings → environment.
    private func arguments(of pid: pid_t, into buffer: inout [UInt8]) -> [String] {
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        // EINVAL for processes we may not inspect. Expected, and not worth
        // reporting — we fall back to the kernel-reported name.
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
            size > MemoryLayout<Int32>.size
        else { return [] }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }

        var cursor = MemoryLayout<Int32>.size

        // Skip the exec path, then its trailing NUL padding.
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        var start = cursor

        while cursor < size, args.count < Int(argc) {
            if buffer[cursor] == 0 {
                args.append(String(decoding: buffer[start..<cursor], as: UTF8.self))
                start = cursor + 1
            }
            cursor += 1
        }
        return args
    }
}
#endif
