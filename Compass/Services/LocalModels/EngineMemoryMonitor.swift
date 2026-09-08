import Darwin
import Foundation
import MLX
import os

/// Abstracts process RSS and MLX memory observations so `NativeMLXGenerator` can be
/// tested without touching `mach_task_basic_info` or `Memory.snapshot`.
///
/// **Design rationale:**
/// - Strategy pattern: production uses `ProcessMemoryMonitor` (real `mach_task`
///   + `Memory`), tests inject `MockMemoryMonitor`.
/// - All methods are non-throwing except `throwIfExceeded`, which preserves the
///   original `AppError` throw site at `NativeMLXGenerator.throwIfProcessRSSExceeded`.
struct VMStatSnapshot: Sendable {
    let freePages: Int
    let activePages: Int
    let inactivePages: Int
    let wiredPages: Int
    let speculativePages: Int
    let purgeablePages: Int
    let compressorPages: Int
    let compressorOccupiedPages: Int
    let pageins: UInt64
    let pageouts: UInt64
    let compressions: UInt64
    let decompressions: UInt64
}

protocol EngineMemoryMonitoring: Sendable {
    func currentRSSMB() -> Int
    func resolvedLimitMB() -> Int
    func throwIfExceeded(limitMB: Int, phase: String) throws
    func logDeviceInfo() async
    func logSnapshot(generationCount: Int)
    func shouldUnloadAfterGeneration() -> Bool
    func currentVMStat() -> VMStatSnapshot?
    func currentThermalState() -> Int
}

/// Production implementation — reads real process RSS and MLX allocator state.
struct ProcessMemoryMonitor: EngineMemoryMonitoring {
    private static let defaultTestingRSSLimitMB = 8 * 1024
    private static let defaultOperationalRSSLimitMB = 10 * 1024

    func currentRSSMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1024 / 1024)
    }

    func resolvedLimitMB() -> Int {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["COMPASS_LOCAL_MODEL_MAX_RSS_MB"], let parsed = Int(configured), parsed > 0 {
            return parsed
        }
        return AppRuntimeEnvironment.launchContext.isTesting
            ? Self.defaultTestingRSSLimitMB
            : Self.defaultOperationalRSSLimitMB
    }

    func throwIfExceeded(limitMB: Int, phase: String) throws {
        let rssMB = currentRSSMB()
        guard rssMB < limitMB else {
            throw AppError.aiServiceError(
                "Local model memory budget exceeded during \(phase): \(rssMB)MB used with limit \(limitMB)MB"
            )
        }
    }

    func logDeviceInfo() async {
        await NativeMLXGenerator.logDeviceAndMemoryInfo()
    }

    func currentVMStat() -> VMStatSnapshot? {
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStat) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rp in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rp, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMStatSnapshot(
            freePages: Int(vmStat.free_count),
            activePages: Int(vmStat.active_count),
            inactivePages: Int(vmStat.inactive_count),
            wiredPages: Int(vmStat.wire_count),
            speculativePages: Int(vmStat.speculative_count),
            purgeablePages: Int(vmStat.purgeable_count),
            compressorPages: Int(vmStat.compressor_page_count),
            compressorOccupiedPages: Int(vmStat.compressor_page_count) > 0 ? Int(vmStat.compressor_page_count) : 0,
            pageins: UInt64(vmStat.pageins),
            pageouts: UInt64(vmStat.pageouts),
            compressions: 0,
            decompressions: 0
        )
    }

    func currentThermalState() -> Int {
        ProcessInfo.processInfo.thermalState.rawValue
    }

    func logSnapshot(generationCount: Int) {
        let snapshot = Memory.snapshot()
        let activeMB = snapshot.activeMemory / (1024 * 1024)
        let cacheMB = snapshot.cacheMemory / (1024 * 1024)
        let peakMB = snapshot.peakMemory / (1024 * 1024)
        let rssMB = currentRSSMB()
        let vm = currentVMStat()
        let thermal = currentThermalState()
        Task {
            // genPeakMB: allocator HIGH-WATER since last generation reset —
            // transients (prefill attention) spike it then free. NOT resident.
            // activeMB/cacheMB are the "how much is held" metrics.
            await AIToolTraceLogger.shared.log(type: "mlx.memory_snapshot", data: [
                "generationCount": generationCount,
                "activeMB": activeMB,
                "cacheMB": cacheMB,
                "genPeakMB": peakMB,
                "rssMB": rssMB,
                "thermalState": thermal,
                "vmFreePages": vm?.freePages ?? 0,
                "vmActivePages": vm?.activePages ?? 0,
                "vmInactivePages": vm?.inactivePages ?? 0,
                "vmWiredPages": vm?.wiredPages ?? 0,
                "vmCompressorPages": vm?.compressorPages ?? 0,
                "vmPageins": vm.map { Int64($0.pageins) } ?? 0,
                "vmPageouts": vm.map { Int64($0.pageouts) } ?? 0
            ])
            if let vm {
                await AIToolTraceLogger.shared.log(type: "mlx.vm_stat", data: [
                    "generationCount": generationCount,
                    "freePages": vm.freePages,
                    "activePages": vm.activePages,
                    "inactivePages": vm.inactivePages,
                    "wiredPages": vm.wiredPages,
                    "speculativePages": vm.speculativePages,
                    "purgeablePages": vm.purgeablePages,
                    "compressorPages": vm.compressorPages,
                    "pageins": Int64(vm.pageins),
                    "pageouts": Int64(vm.pageouts),
                    "rssMB": rssMB,
                    "thermalState": thermal
                ])
            }
        }
    }

    func shouldUnloadAfterGeneration() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["COMPASS_LOCAL_MODEL_UNLOAD_AFTER_GENERATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        {
            switch configured {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: break
            }
        }
        return false
    }
}

#if DEBUG
/// Test double — never touches `mach_task` or MLX.
final class MockMemoryMonitor: EngineMemoryMonitoring, @unchecked Sendable {
    var stubRSSMB: Int = 0
    var stubLimitMB: Int = 10 * 1024
    var stubShouldUnload = false
    private(set) var throwIfExceededCalls: [(limit: Int, phase: String)] = []
    private(set) var logSnapshotCalls = 0

    func currentRSSMB() -> Int { stubRSSMB }
    func resolvedLimitMB() -> Int { stubLimitMB }
    func throwIfExceeded(limitMB: Int, phase: String) throws {
        throwIfExceededCalls.append((limitMB, phase))
        if stubRSSMB >= limitMB {
            throw AppError.aiServiceError("mock exceeded \(phase)")
        }
    }
    func logDeviceInfo() async {}
    func logSnapshot(generationCount: Int) { logSnapshotCalls += 1 }
    func shouldUnloadAfterGeneration() -> Bool { stubShouldUnload }
    func currentVMStat() -> VMStatSnapshot? { nil }
    func currentThermalState() -> Int { 0 }
}
#endif
