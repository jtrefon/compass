import Foundation
import Darwin

/// `struct xsw_usage` from sys/sysctl.h (not imported into Swift; mirrored here).
private struct SwapUsage {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var available: UInt64 = 0
    var pagesize: UInt32 = 0
    var encrypted: UInt32 = 0
}

/// Locks the process's memory so the OS cannot swap it out or compress it.
///
/// Measured context: this 16GB M4 had **7GB in swap** (`vm.swapusage`) and
/// 200-400k compressed pages while the model ran at 12 tps vs a 35+ tps
/// benchmark. macOS compresses reclaimable pages before the GPU can use the
/// physical memory — every KV/logit allocation then stalls on
/// decompression/reclaim. `mlockall` marks the app's pages non-reclaimable,
/// forcing the OS to reclaim OTHER processes instead of our inference memory.
///
/// Mechanics:
/// - `RLIMIT_MEMLOCK` is unlimited by default on macOS — no privileges needed.
/// - `MCL_CURRENT | MCL_FUTURE`: everything mapped now AND later (KV growth,
///   generation buffers, weights) stays resident.
/// - MLX/Metal GPU-private buffers are already wired by the GPU driver; this
///   covers the CPU-side allocations (weights, tokenizer, model metadata,
///   buffers) that the compressor was thrashing on.
///
/// Tradeoff: with MCL_FUTURE, if the machine genuinely lacks physical RAM for
/// a future allocation, the allocation FAILS (ENOMEM) instead of swapping —
/// the process may crash instead of stalling. Escape hatch:
/// `COMPASS_DISABLE_MEMORY_LOCK=1`.
enum ProcessMemoryLock {
    static func engageIfEnabled() {
        guard ProcessInfo.processInfo.environment["COMPASS_DISABLE_MEMORY_LOCK"] == nil else {
            return
        }
        let flags = MCL_CURRENT | MCL_FUTURE
        let result = mlockall(Int32(flags))
        let errnoValue = result == 0 ? 0 : errno
        let residentBytes = residentBytes()
        // Gated: this logs every session that mlockall failed (ENOSYS on
        // macOS) — useful in Debug, noise in Release.
        guard TelemetryGate.isEnabled else { return }
        Task {
            await AIToolTraceLogger.shared.log(type: "mlx.memory_lock", data: [
                "engaged": result == 0,
                "errno": errnoValue,
                // macOS does NOT implement mlockall (ENOSYS = 78): the call
                // always fails here. MLX's Metal buffers are GPU-private and
                // already wired by the GPU driver; the observed swap pressure
                // comes from OTHER processes, which no process-local lock can
                // protect against. Per-region mlock() on CPU-side allocations
                // (weights mmap) is the only viable follow-up.
                "mlockallSupportedOnMacOS": errnoValue != 78,
                "residentMBAtLock": residentBytes / 1_048_576,
                "swapUsedMB": swapUsedMB()
            ])
        }
    }

    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rp in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rp, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private static func swapUsedMB() -> Int {
        var swap = SwapUsage()
        var size = MemoryLayout<SwapUsage>.size
        let result = withUnsafeMutablePointer(to: &swap) { ptr in
            ptr.withMemoryRebound(to: Int8.self, capacity: size) { rp in
                sysctlbyname("vm.swapusage", rp, &size, nil, 0)
            }
        }
        guard result == 0 else { return 0 }
        return Int(swap.used / 1_048_576)
    }
}