//
//  CodebaseIndex.swift
//  Compass
//
//  Created by Cascade on 23/12/2025.
//

import Combine
import Foundation
import SQLite3

/// Tracks initialization state for async CodebaseIndex creation
/// Supports multiple concurrent waiters via an array of continuations.
public actor CodebaseIndexInitializationState {
    public enum State: Sendable {
        case pending
        case initializing
        case initialized
        case failed(Error)
    }

    private var state: State = .pending
    private var continuations: [CheckedContinuation<Void, Error>] = []

    public func awaitInitialization() async throws {
        switch state {
        case .initialized:
            return
        case .failed(let error):
            throw error
        case .pending, .initializing:
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        }
    }

    func startInitializing() {
        state = .initializing
    }

    func complete() {
        state = .initialized
        let conts = continuations
        continuations = []
        for c in conts { c.resume() }
    }

    func fail(_ error: Error) {
        state = .failed(error)
        let conts = continuations
        continuations = []
        for c in conts { c.resume(throwing: error) }
    }
}

// Thread safety: all mutable state is either actor-isolated (IndexCoordinator,
// initializationState) or initialized once in init and read-only thereafter
// (database, projectRoot, etc.). The nonisolated init is safe because mutation
// only occurs after the instance is returned, at which point callers must await
// initializationState.awaitInitialization(), and subsequent mutations go through
// actor-isolated paths.
public class CodebaseIndex: CodebaseIndexProtocol, @unchecked Sendable {
    let eventBus: EventBusProtocol
    let coordinator: IndexCoordinator
    public let database: DatabaseStore
    let indexer: IndexerActor
    let queryService: QueryService
    let aiService: AIService
    let dbPath: String
    let projectRoot: URL
    let excludePatterns: [String]
    var isEnabled: Bool
    /// Initialization state for async creation
    public let initializationState = CodebaseIndexInitializationState()

    /// Tracks the coordinator start task so it can be cancelled in stop()
    var coordinatorStartTask: Task<Void, Never>?

    nonisolated init(
        eventBus: EventBusProtocol,
        projectRoot: URL,
        aiService: AIService,
        config: IndexConfiguration = .default
    ) throws {
        self.eventBus = eventBus
        self.projectRoot = projectRoot
        self.aiService = aiService
        let resolvedConfig = Self.resolveConfiguration(projectRoot: projectRoot, config: config)
        self.excludePatterns = resolvedConfig.excludePatterns
        self.isEnabled = resolvedConfig.configuration.enabled

        self.dbPath = Self.makeDatabasePath(
            projectRoot: projectRoot,
            storageDirectoryPath: resolvedConfig.configuration.storageDirectoryPath
        )

        self.database = try DatabaseStore(path: dbPath)
        self.indexer = IndexerActor(
            database: database,
            config: resolvedConfig.configuration,
            projectRoot: projectRoot
        )
        self.queryService = QueryService(database: database)
        self.coordinator = IndexCoordinator(
            eventBus: eventBus,
            indexer: indexer,
            config: resolvedConfig.configuration,
            projectRoot: projectRoot,
            activityCoordinator: AgentActivityCoordinator.shared,
            backgroundWorkGovernor: .shared
        )
    }

    /// Async factory method for non-blocking initialization
    /// Creates the index off the main actor and returns a fully initialized instance
    /// This method avoids actor isolation contention by using the async createAsync pattern
    public static func create(
        eventBus: EventBusProtocol,
        projectRoot: URL,
        aiService: AIService,
        config: IndexConfiguration = .default
    ) async throws -> CodebaseIndex {
        let createStart = Date()

        // Use createAsync which creates the index synchronously but without blocking
        // This avoids the actor isolation contention that occurred with Task.detached + .value
        let index = CodebaseIndex.createAsync(
            eventBus: eventBus,
            projectRoot: projectRoot,
            aiService: aiService,
            config: config
        )

        // Start the coordinator in the background and mark as ready
        let task = Task.detached(priority: .userInitiated) { [weak index] in
            guard let index else { return }
            await index.initializationState.startInitializing()
            await index.coordinator.start(projectRoot: projectRoot)
            await index.initializationState.complete()
        }
        index.coordinatorStartTask = task

        // Don't await the coordinator start - let it run in background
        // The index is usable once initializationState.awaitInitialization() completes
        return index
    }

    /// Creates a placeholder index that initializes in the background
    /// The index becomes usable once initializationState.awaitInitialization() completes
    public static func createAsync(
        eventBus: EventBusProtocol,
        projectRoot: URL,
        aiService: AIService,
        config: IndexConfiguration = .default
    ) -> CodebaseIndex {
        // Create a lightweight placeholder synchronously
        // This requires a temporary database that will be replaced
        let resolvedConfig = Self.resolveConfiguration(projectRoot: projectRoot, config: config)
        let dbPath = Self.makeDatabasePath(
            projectRoot: projectRoot,
            storageDirectoryPath: resolvedConfig.configuration.storageDirectoryPath
        )

        let tempDatabase: DatabaseStore = (try? DatabaseStore(path: dbPath))
            ?? (try! DatabaseStore(path: NSTemporaryDirectory() + "codebase-index-\(UUID().uuidString).db"))

        let index = CodebaseIndex(
            eventBus: eventBus,
            projectRoot: projectRoot,
            aiService: aiService,
            database: tempDatabase,
            config: resolvedConfig
        )

        return index
    }

    /// Internal initializer for async creation
    private nonisolated init(
        eventBus: EventBusProtocol,
        projectRoot: URL,
        aiService: AIService,
        database: DatabaseStore,
        config: ResolvedIndexConfiguration
    ) {
        let initStart = Date()

        self.eventBus = eventBus
        self.projectRoot = projectRoot
        self.aiService = aiService
        self.excludePatterns = config.excludePatterns
        self.isEnabled = config.configuration.enabled
        self.dbPath = Self.makeDatabasePath(
            projectRoot: projectRoot,
            storageDirectoryPath: config.configuration.storageDirectoryPath
        )

        self.database = database

        let indexerStart = Date()
        self.indexer = IndexerActor(
            database: database,
            config: config.configuration,
            projectRoot: projectRoot
        )

        let queryStart = Date()
        self.queryService = QueryService(database: database)

        let coordStart = Date()
        self.coordinator = IndexCoordinator(
            eventBus: eventBus,
            indexer: indexer,
            config: config.configuration,
            projectRoot: projectRoot,
            activityCoordinator: AgentActivityCoordinator.shared,
            backgroundWorkGovernor: .shared
        )

    }

    private struct ResolvedIndexConfiguration {
        let configuration: IndexConfiguration
        let excludePatterns: [String]
    }

    private nonisolated static func resolveConfiguration(
        projectRoot: URL,
        config: IndexConfiguration
    ) -> ResolvedIndexConfiguration {
        let resolvedExcludePatterns = IndexExcludePatternManager.loadExcludePatterns(
            projectRoot: projectRoot,
            defaultPatterns: config.excludePatterns
        )
        let resolvedConfig = IndexConfiguration(
            enabled: config.enabled,
            debounceMs: config.debounceMs,
            bulkOperationDebounceMs: config.bulkOperationDebounceMs,
            bulkOperationThreshold: config.bulkOperationThreshold,
            excludePatterns: resolvedExcludePatterns,
            storageDirectoryPath: config.storageDirectoryPath
        )
        return ResolvedIndexConfiguration(
            configuration: resolvedConfig, excludePatterns: resolvedExcludePatterns)
    }

    /// Must be called at the top of every protocol method to ensure the index
    /// is fully initialized before use. Throws if initialization failed.
    func ensureReady() async throws {
        try await initializationState.awaitInitialization()
    }

    private nonisolated static func makeDatabasePath(
        projectRoot: URL, storageDirectoryPath: String?
    ) -> String {
        resolveIndexDirectory(projectRoot: projectRoot, storageDirectoryPath: storageDirectoryPath)
            .appendingPathComponent("codebase.sqlite")
            .path
    }
}
