//
//  ProjectCoordinator.swift
//  Compass
//
//  Created by Cascade on 02/01/2026.
//

import Combine
import Foundation

/// Manages the lifecycle of a project, including indexing coordination and project-specific services.
@MainActor
class ProjectCoordinator: ObservableObject {
    private let aiService: AIService
    private let errorManager: any ErrorManagerProtocol
    private let eventBus: any EventBusProtocol
    private let conversationManager: any ConversationManagerProtocol
    private let settingsStore: SettingsStore
    private let backgroundWorkGovernor: BackgroundWorkGovernor
    private(set) var currentProjectRoot: URL?
    private var rootWatcher: ProjectRootFileWatcher?

    @Published private(set) var codebaseIndex: (any CodebaseIndexProtocol)?
    @Published private(set) var isInitializing: Bool = false {
        didSet {
            if !isInitializing {
                let waiters = initContinuations
                initContinuations = []
                for continuation in waiters {
                    continuation.resume()
                }
            }
        }
    }
    @Published private(set) var initializationError: Error?

    private var pendingAutoReindexTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?
    /// Multiple concurrent callers can await initialization — one slot would
    /// hang every caller after the first.
    private var initContinuations: [CheckedContinuation<Void, Never>] = []

    /// Await project initialization completion. Returns once isInitializing transitions to false.
    func waitForInitialization() async {
        if !isInitializing { return }
        await withCheckedContinuation { continuation in
            initContinuations.append(continuation)
        }
    }

    init(
        aiService: AIService,
        errorManager: any ErrorManagerProtocol,
        eventBus: any EventBusProtocol,
        conversationManager: any ConversationManagerProtocol
    ) {
        self.aiService = aiService
        self.errorManager = errorManager
        self.eventBus = eventBus
        self.conversationManager = conversationManager
        self.settingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)
        self.backgroundWorkGovernor = .shared
    }

    /// Configure project asynchronously - does NOT block the main thread
    func configureProject(root: URL) {
        let configStart = Date()

        // Check for duplicate calls
        if let current = currentProjectRoot, current == root && isInitializing {
            return
        }

        if let current = currentProjectRoot, current == root, codebaseIndex != nil {
            return
        }

        currentProjectRoot = root
        pendingAutoReindexTask?.cancel()
        pendingAutoReindexTask = nil
        initializationTask?.cancel()
        initializationTask = nil

        rootWatcher?.stop()
        rootWatcher = nil

        codebaseIndex?.stop()
        codebaseIndex = nil
        initializationError = nil

        // Start async initialization
        isInitializing = true


        // Capture Sendable values for the detached task
        let eventBus = self.eventBus
        let aiService = self.aiService
        let ss = self.settingsStore
        _ = self.backgroundWorkGovernor

        // CRITICAL: Use Task.detached with [weak self] but WITHOUT immediate guard.
        // This keeps the closure non-isolated while allowing weak access to self for MainActor hops.
        initializationTask = Task.detached(priority: .userInitiated) { [weak self] in

            // Initialize logger early (non-blocking)
            await IndexLogger.shared.setup(projectRoot: root)
            await IndexLogger.shared.log(
                "ProjectCoordinator: Configuring project at \(root.path)")

            do {
                let indexStart = Date()

                // Create index asynchronously - this is the heavy operation
                let index = try await CodebaseIndex.create(
                    eventBus: eventBus,
                    projectRoot: root,
                    aiService: aiService
                )

                let indexDuration = Date().timeIntervalSince(indexStart) * 1000

                // Check if cancelled before hopping to MainActor
                if Task.isCancelled {
                    return
                }

                // Use MainActor.run specifically for final state synchronization
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    // A cancelled predecessor must never install its index over
                    // a newer project's — re-check after the actor hop.
                    if Task.isCancelled || self.currentProjectRoot != root { return }
                    self.codebaseIndex = index
                    self.isInitializing = false  // CORE INIT DONE
                    index.start()

                    // Update conversation manager with new project context - safe on MainActor
                    conversationManager.updateCodebaseIndex(index)
                    conversationManager.updateProjectRoot(root)

                    self.startRootWatcher(projectRoot: root)
                }

                // Post-init background configuration - this continues while isInitializing is false
                let isIndexEnabled = ss.bool(
                    forKey: AppConstants.Storage.codebaseIndexEnabledKey, default: true)
                await index.setEnabled(isIndexEnabled)

                if isIndexEnabled, await Self.shouldRunInitialProjectReindex(index: index, projectRoot: root) {
                    await BackgroundWorkGovernor.shared.waitUntilReady(
                        for: .indexing,
                        reason: "initial_project_reindex"
                    )
                    // Start reindex in background
                    await index.reindexProject()
                } else {
                    await IndexLogger.shared.log(
                        "ProjectCoordinator: Skipping initial project reindex because persisted index data already exists"
                    )
                }

                // ProjectMemoryInitializer disabled — it fires a full local model inference
                // on every project open, competing with user requests for the MLX engine.
                // Re-enable when cloud-only routing is available for this background task.

            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    if Task.isCancelled || self.currentProjectRoot != root { return }
                    self.codebaseIndex = nil
                    self.isInitializing = false
                    self.initializationError = error
                    self.errorManager.handle(
                        .unknown(
                            "Failed to initialize CodebaseIndex: \(error.localizedDescription)"))
                }
            }
        }
    }

    func reindexProject() {
        codebaseIndex?.reindexProject()
    }

    func rebuildIndex(overwriteDB: Bool) {
        guard let root = currentProjectRoot else {
            Task {
                await IndexLogger.shared.log(
                    "ProjectCoordinator: Reindex requested but project root is not set")
            }
            return
        }

        pendingAutoReindexTask?.cancel()
        pendingAutoReindexTask = nil
        initializationTask?.cancel()
        initializationTask = nil

        codebaseIndex?.stop()
        codebaseIndex = nil
        isInitializing = true

        if overwriteDB {
            cleanupIndexDatabase(projectRoot: root)
        }

        initializeAndStartIndex(projectRoot: root)
    }

    private func cleanupIndexDatabase(projectRoot: URL) {
        Task {
            await IndexLogger.shared.setup(projectRoot: projectRoot)
            await IndexLogger.shared.log(
                "ProjectCoordinator: Rebuilding index DB (delete + recreate)")
        }

        let dbURL = CodebaseIndex.indexDatabaseURL(projectRoot: projectRoot)
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")

        do {
            try FileManager.default.createDirectory(
                at: dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for url in [dbURL, walURL, shmURL] {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            errorManager.handle(.unknown("Failed to reset index DB: \(error.localizedDescription)"))
        }
    }

    private func initializeAndStartIndex(projectRoot: URL) {
        // Capture Sendable values for the detached task
        let eventBus = self.eventBus
        let aiService = self.aiService
        let settingsStore = self.settingsStore
        _ = self.backgroundWorkGovernor

        // CRITICAL: Use Task.detached to escape @MainActor context
        initializationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            do {
                let index = try await CodebaseIndex.create(
                    eventBus: eventBus,
                    projectRoot: projectRoot,
                    aiService: aiService
                )

                if Task.isCancelled { return }

                // Use fire-and-forget to update main actor state without blocking
                let indexCopy = index
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if Task.isCancelled || self.currentProjectRoot != projectRoot { return }
                    self.codebaseIndex = indexCopy
                    self.isInitializing = false
                    indexCopy.start()

                    conversationManager.updateCodebaseIndex(indexCopy)
                    conversationManager.updateProjectRoot(projectRoot)
                }

                await self.startRootWatcher(projectRoot: projectRoot)

                let isIndexEnabled = settingsStore.bool(
                    forKey: AppConstants.Storage.codebaseIndexEnabledKey, default: true)
                await index.setEnabled(isIndexEnabled)

                if isIndexEnabled {
                    await backgroundWorkGovernor.waitUntilReady(
                        for: .indexing,
                        reason: "rebuild_project_reindex"
                    )
                    await index.reindexProject()
                } else {
                    await IndexLogger.shared.log(
                        "ProjectCoordinator: Reindex requested but Codebase Index is disabled")
                }

                // ProjectMemoryInitializer disabled — see comment above.
            } catch {
                await MainActor.run {
                    if Task.isCancelled || self.currentProjectRoot != projectRoot { return }
                    self.codebaseIndex = nil
                    self.isInitializing = false
                    self.initializationError = error
                    self.errorManager.handle(
                        .unknown("Failed to rebuild CodebaseIndex: \(error.localizedDescription)"))
                }
            }
        }
    }

    nonisolated static func shouldRunInitialProjectReindex(
        index: CodebaseIndex,
        projectRoot: URL
    ) async -> Bool {
        let dbURL = CodebaseIndex.indexDatabaseURL(projectRoot: projectRoot)
        let dbExists = FileManager.default.fileExists(atPath: dbURL.path)
        let hasPersistedIndexData = await index.hasPersistedIndexData()
        return shouldRunInitialProjectReindex(
            dbExists: dbExists,
            hasPersistedIndexData: hasPersistedIndexData
        )
    }

    nonisolated static func shouldRunInitialProjectReindex(
        dbExists: Bool,
        hasPersistedIndexData: Bool
    ) -> Bool {
        guard dbExists else { return true }
        return !hasPersistedIndexData
    }

    func setIndexEnabled(_ enabled: Bool) {
        settingsStore.set(enabled, forKey: AppConstants.Storage.codebaseIndexEnabledKey)
        codebaseIndex?.setEnabled(enabled)
        if enabled {
            reindexProject()
        }
    }

    private func scheduleAutoReindex(root: URL) {
        pendingAutoReindexTask?.cancel()
        pendingAutoReindexTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self else { return }

            if let index = await self.codebaseIndex {
                await self.backgroundWorkGovernor.waitUntilReady(
                    for: .indexing,
                    reason: "scheduled_auto_reindex"
                )
                await index.reindexProject()
            }
        }
    }

    private func startRootWatcher(projectRoot: URL) {
        let excludePatterns = IndexExcludePatternManager.loadExcludePatterns(
            projectRoot: projectRoot,
            defaultPatterns: IndexConfiguration.default.excludePatterns
        )
        let watcher = ProjectRootFileWatcher(
            rootURL: projectRoot,
            eventBus: eventBus,
            excludePatterns: excludePatterns
        )
        rootWatcher = watcher
        watcher.start()
    }
}
