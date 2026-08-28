import Darwin
import Foundation
import MLX

/// Abstracts process RSS and MLX memory observations so `NativeMLXGenerator` can be
/// tested without touching `mach_task_basic_info` or `Memory.snapshot`.
///
/// **Design rationale:**
/// - Strategy pattern: production uses `ProcessMemoryMonitor` (real `mach_task`
///   + `Memory`), tests inject `MockMemoryMonitor`.
/// - All methods are non-throwing except `throwIfExceeded`, which preserves the
///   original `AppError` throw site at `NativeMLXGenerator.throwIfProcessRSSExceeded`.
protocol EngineMemoryMonitoring: Sendable {
    func currentRSSMB() -> Int
    func resolvedLimitMB() -> Int
    func throwIfExceeded(limitMB: Int, phase: String) throws
    func logDeviceInfo() async
    func logSnapshot(generationCount: Int)
    func shouldUnloadAfterGeneration() -> Bool
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

    func logSnapshot(generationCount: Int) {
        let snapshot = Memory.snapshot()
        let activeMB = snapshot.activeMemory / (1024 * 1024)
        let cacheMB = snapshot.cacheMemory / (1024 * 1024)
        let peakMB = snapshot.peakMemory / (1024 * 1024)
        Task {
            await AIToolTraceLogger.shared.log(type: "mlx.memory_snapshot", data: [
                "generationCount": generationCount,
                "activeMB": activeMB,
                "cacheMB": cacheMB,
                "peakMB": peakMB
            ])
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
}
#endif
