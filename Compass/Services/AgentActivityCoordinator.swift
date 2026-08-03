//
//  AgentActivityCoordinator.swift
//  Compass
//
//  Coordinates agent activity tracking across all long-running operations.
//  Uses reference counting to manage power assertions for:
//  - API sending
//  - Tool execution (commands, downloads, compilations)
//  - MLX model inference
//  - RAG operations
//  - Indexing operations
//

import Foundation

/// Types of agent activities that prevent system sleep
public enum AgentActivityType: String, Sendable {
    case apiSending = "api_sending"
    case toolExecution = "tool_execution"
    case mlxInference = "mlx_inference"
    case ragRetrieval = "rag_retrieval"
    case indexing = "indexing"
    case embeddingGeneration = "embedding_generation"
    case modelDownload = "model_download"
}

/// Token representing an active agent activity.
/// Releases the activity when deallocated.
// Thread safety: all mutable state (id, hasEnded) is protected by `lock`.
// The coordinator reference is read-only after init.
public final class AgentActivityToken: @unchecked Sendable {
    private let id: UUID
    private let type: AgentActivityType
    private weak var coordinator: AgentActivityCoordinator?
    private let lock = NSLock()
    private var hasEnded = false
    
    init(id: UUID, type: AgentActivityType, coordinator: AgentActivityCoordinator) {
        self.id = id
        self.type = type
        self.coordinator = coordinator
    }
    
    deinit {
        // Release the activity when token goes out of scope
        end()
    }
    
    /// Manually end the activity before token deallocation
    public func end() {
        lock.lock()
        defer { lock.unlock() }
        
        guard !hasEnded else { return }
        hasEnded = true
        
        coordinator?.releaseActivity(id: id, type: type)
    }
}

/// Protocol for agent activity coordination - allows mocking in tests
public protocol AgentActivityCoordinating: AnyObject, Sendable {
    /// Whether any agent activity is currently active
    var hasActiveActivities: Bool { get }
    
    /// Number of active activities
    var activeActivityCount: Int { get }
    
    /// Begin an agent activity, returning a token that releases when deallocated
    func beginActivity(type: AgentActivityType) -> AgentActivityToken
    
    /// Perform a scoped activity that automatically releases when complete
    func withActivity<T>(type: AgentActivityType, _ operation: @Sendable () async throws -> T) async rethrows -> T

    /// Check if a specific activity type is currently active
    func isActivityTypeActive(_ type: AgentActivityType) -> Bool
}

/// Coordinates all agent activities to manage power assertions.
/// Uses reference counting to ensure power assertion is held while any activity is active.
/// Thread-safe via NSLock - can be accessed from any actor/queue.
// Thread safety: `activitiesByType` dictionary is protected by `lock`.
// Power management state is read and updated only while the lock is held.
public final class AgentActivityCoordinator: AgentActivityCoordinating, @unchecked Sendable {
    
    // MARK: - Properties
    
    /// Shared instance for global access
    public static let shared = AgentActivityCoordinator()
    
    /// Power management service to control sleep prevention
    private let powerManagementService: PowerManagementServiceProtocol
    
    /// Active activities by type for debugging and status display
    private var activitiesByType: [AgentActivityType: Set<UUID>] = [:]
    
    /// Lock for thread-safe access to activities
    private let lock = NSLock()
    
    /// Total count of active activities
    public var activeActivityCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activitiesByType.values.reduce(0) { $0 + $1.count }
    }
    
    /// Whether any agent activity is currently active
    public var hasActiveActivities: Bool {
        activeActivityCount > 0
    }
    
    // MARK: - Initialization
    
    init(powerManagementService: PowerManagementServiceProtocol = PowerManagementService()) {
        self.powerManagementService = powerManagementService
    }
    
    // MARK: - Public Methods
    
    /// Begin an agent activity, returning a token that releases when deallocated
    public func beginActivity(type: AgentActivityType) -> AgentActivityToken {
        let id = UUID()
        
        lock.lock()
        
        // Add to tracking
        if activitiesByType[type] == nil {
            activitiesByType[type] = []
        }
        activitiesByType[type]?.insert(id)
        
        let count = activitiesByType.values.reduce(0) { $0 + $1.count }
        
        logActivityStarted(type: type, id: id, totalCount: count)
        
        // Ensure power assertion is active
        updatePowerAssertionLocked()
        
        lock.unlock()
        
        return AgentActivityToken(id: id, type: type, coordinator: self)
    }
    
    /// Perform a scoped activity that automatically releases when complete
    public func withActivity<T>(type: AgentActivityType, _ operation: @Sendable () async throws -> T) async rethrows -> T {
        let token = beginActivity(type: type)
        defer { token.end() }
        return try await operation()
    }
    
    /// Release an activity by ID (called by token)
    func releaseActivity(id: UUID, type: AgentActivityType) {
        lock.lock()
        defer { lock.unlock() }
        
        // Remove from tracking
        activitiesByType[type]?.remove(id)
        
        // Clean up empty sets
        if activitiesByType[type]?.isEmpty == true {
            activitiesByType[type] = nil
        }
        
        let count = activitiesByType.values.reduce(0) { $0 + $1.count }
        
        logActivityEnded(type: type, id: id, totalCount: count)
        
        // Update power assertion state
        updatePowerAssertionLocked()
    }
    
    // MARK: - Private Methods
    
    /// Must be called while holding lock
    private func updatePowerAssertionLocked() {
        let hasActive = !activitiesByType.values.filter { !$0.isEmpty }.isEmpty
        
        if hasActive {
            // At least one activity active - ensure power assertion
            if !powerManagementService.isActive {
                powerManagementService.beginPreventingSleep()
            }
        } else {
            // No activities - release power assertion
            if powerManagementService.isActive {
                powerManagementService.stopPreventingSleep()
            }
        }
    }
    
    private func logActivityStarted(type: AgentActivityType, id: UUID, totalCount: Int) {
        Task {
            await AppLogger.shared.debug(
                category: .app,
                message: "activity.started",
                context: AppLogger.LogCallContext(metadata: [
                    "type": type.rawValue,
                    "id": id.uuidString,
                    "totalCount": totalCount,
                ])
            )
        }
    }

    private func logActivityEnded(type: AgentActivityType, id: UUID, totalCount: Int) {
        Task {
            await AppLogger.shared.debug(
                category: .app,
                message: "activity.ended",
                context: AppLogger.LogCallContext(metadata: [
                    "type": type.rawValue,
                    "id": id.uuidString,
                    "totalCount": totalCount,
                ])
            )
        }
    }
}

// MARK: - Convenience Extensions

extension AgentActivityCoordinator {
    /// Get a summary of active activities for debugging/display
    public var activitySummary: String {
        lock.lock()
        defer { lock.unlock() }
        
        guard hasActiveActivities else {
            return "No active agent activities"
        }
        
        let parts = activitiesByType.compactMap { type, ids -> String? in
            guard !ids.isEmpty else { return nil }
            return "\(type.rawValue): \(ids.count)"
        }
        
        return "Active: " + parts.joined(separator: ", ")
    }
    
    /// Check if a specific activity type is active
    public func isActivityTypeActive(_ type: AgentActivityType) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (activitiesByType[type]?.count ?? 0) > 0
    }
}

enum BackgroundWorkKind: String, Sendable {
    case indexing
    case embeddingUpgrade
}

// Thread safety: all config properties are `let` constants. The
// activityCoordinator reference is read-only. The log-throttle timestamp
// (`lastGovernorLogAt`) is only accessed from the async context of waitUntilReady.
final class BackgroundWorkGovernor: @unchecked Sendable {
    static let shared = BackgroundWorkGovernor(activityCoordinator: AgentActivityCoordinator.shared)

    private let activityCoordinator: any AgentActivityCoordinating
    private let quietPeriodNanoseconds: UInt64
    private let pollIntervalNanoseconds: UInt64 = 500_000_000
    private let cpuLoadThresholdPerCore: Double
    private let rssThresholdMB: Int

    init(activityCoordinator: any AgentActivityCoordinating) {
        self.activityCoordinator = activityCoordinator
        let environment = ProcessInfo.processInfo.environment
        self.quietPeriodNanoseconds = Self.resolveInt(
            environment["COMPASS_BACKGROUND_WORK_QUIET_MS"],
            defaultValue: 4000,
            minimum: 250
        ) * 1_000_000
        self.cpuLoadThresholdPerCore = Self.resolveDouble(
            environment["COMPASS_BACKGROUND_WORK_CPU_LOAD_PER_CORE_THRESHOLD"],
            defaultValue: 0.8,
            minimum: 0.1
        )
        self.rssThresholdMB = Self.resolveInt(
            environment["COMPASS_BACKGROUND_WORK_RSS_THRESHOLD_MB"],
            defaultValue: 2048,
            minimum: 256
        )
    }

    private var lastGovernorLogAt: ContinuousClock.Instant?

    /// Logs at most once per 10s so a long deferral can't flood stdout (a previous
    /// bug spun this print millions of times and produced multi-GB logs).
    private func logGovernor(_ message: String) {
        let now = ContinuousClock.now
        if let last = lastGovernorLogAt, last.duration(to: now) < .seconds(10) { return }
        lastGovernorLogAt = now
    }

    func waitUntilReady(for kind: BackgroundWorkKind, reason: String) async {
        let quietPeriod = Duration.milliseconds(Int64(quietPeriodNanoseconds / 1_000_000))
        while true {
            // Honour cancellation in the outer loop. The previous `try? await
            // Task.sleep` swallowed CancellationError, so a cancelled wait re-looped
            // immediately and spun forever.
            if Task.isCancelled { return }
            if let stressReason = currentStressReason(ignoring: kind) {
                logGovernor("[BackgroundWorkGovernor] delaying \(kind.rawValue) reason=\(reason) stress=\(stressReason)")
                do {
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                } catch {
                    return
                }
                continue
            }

            let quietStart = ContinuousClock.now
            while quietStart.duration(to: ContinuousClock.now) < quietPeriod {
                if Task.isCancelled { return }
                if let stressReason = currentStressReason(ignoring: kind) {
                    logGovernor("[BackgroundWorkGovernor] paused \(kind.rawValue) reason=\(reason) stress=\(stressReason)")
                    break
                }
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }

            if currentStressReason(ignoring: kind) == nil {
                return
            }
        }
    }

    private func currentStressReason(ignoring kind: BackgroundWorkKind) -> String? {
        if activityCoordinator.isActivityTypeActive(.mlxInference) {
            return "mlx_inference"
        }
        if activityCoordinator.isActivityTypeActive(.apiSending) {
            return "api_sending"
        }
        if activityCoordinator.isActivityTypeActive(.toolExecution) {
            return "tool_execution"
        }
        if kind != .embeddingUpgrade && activityCoordinator.isActivityTypeActive(.embeddingGeneration) {
            return "embedding_generation"
        }

        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            return "thermal_serious"
        case .critical:
            return "thermal_critical"
        default:
            break
        }

        let rssMB = Self.currentProcessRSSMB()
        if rssMB >= rssThresholdMB {
            return "rss_\(rssMB)mb"
        }

        let normalizedLoad = Self.normalizedCPULoad()
        if normalizedLoad >= cpuLoadThresholdPerCore {
            return String(format: "cpu_load_%.2f", normalizedLoad)
        }

        return nil
    }

    private static func normalizedCPULoad() -> Double {
        var averages = [Double](repeating: 0, count: 3)
        let samples = getloadavg(&averages, Int32(averages.count))
        guard samples > 0 else { return 0 }
        let coreCount = max(1, ProcessInfo.processInfo.processorCount)
        return averages[0] / Double(coreCount)
    }

    private static func currentProcessRSSMB() -> Int {
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

    private static func resolveInt(_ value: String?, defaultValue: UInt64, minimum: UInt64) -> UInt64 {
        guard let value,
              let parsed = UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultValue
        }
        return max(minimum, parsed)
    }

    private static func resolveInt(_ value: String?, defaultValue: Int, minimum: Int) -> Int {
        guard let value,
              let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultValue
        }
        return max(minimum, parsed)
    }

    private static func resolveDouble(_ value: String?, defaultValue: Double, minimum: Double) -> Double {
        guard let value,
              let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultValue
        }
        return max(minimum, parsed)
    }
}
