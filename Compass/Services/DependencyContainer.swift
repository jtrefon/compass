//
//  DependencyContainer.swift
//  Compass
//
//  Created by AI Assistant on 20/12/2025.
//

import Combine
import SwiftUI

func elapsedSince(_ start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

func withTimeout<T: Sendable>(seconds: UInt64, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Dependency injection container for managing service instances
@MainActor
class DependencyContainer: ObservableObject {
    internal let settingsStore: SettingsStore

    /// Tracks whether heavy initialization is complete
    @Published private(set) var isInitialized: Bool = false
    @Published private(set) var initializationStatus: String = "Starting..."

    init(
        launchContext: AppLaunchContext = AppRuntimeEnvironment.launchContext,
        settingsDefaults: UserDefaults? = nil
    ) {
        let _initStart = Date()
        StartupLogger.log("DependencyContainer.init START")

        settingsStore = SettingsStore(
            userDefaults: settingsDefaults ?? AppRuntimeEnvironment.makeUserDefaults(for: launchContext)
        )

        // Create lightweight services immediately
        StartupLogger.log("Creating lightweight services...")

        let errorManager = ErrorManager()
        _errorManager = errorManager
        _eventBus = EventBus()
        _commandRegistry = CommandRegistry()
        _uiRegistry = UIRegistry()
        _uiService = UIService(errorManager: errorManager, eventBus: _eventBus)
        _fileSystemService = FileSystemService()
        _workspaceService = WorkspaceService(
            errorManager: errorManager,
            eventBus: _eventBus,
            fileSystemService: _fileSystemService
        )
        _windowProvider = WindowProvider()
        _fileDialogService = FileDialogService(windowProvider: _windowProvider)
        _fileEditorService = FileEditorService(
            errorManager: errorManager,
            fileSystemService: _fileSystemService,
            eventBus: _eventBus
        )
        _diagnosticsStore = DiagnosticsStore(eventBus: _eventBus)

        let languageModuleManager = LanguageModuleManager(
            modules: LanguageModuleManager.shared.availableLanguages.compactMap { language in
                LanguageModuleManager.shared.getModule(for: language)
            },
            settingsStore: settingsStore
        )
        _languageModuleManager = languageModuleManager

        _unifiedLintingFramework = UnifiedLintingFramework(
            eventBus: _eventBus,
            diagnosticsStore: _diagnosticsStore,
            languageModuleManager: languageModuleManager,
            workspaceRootProvider: { [weak _workspaceService] in
                _workspaceService?.currentDirectory
            }
        )
        _activityCoordinator = AgentActivityCoordinator.shared
        StartupLogger.log("Lightweight services done", elapsedMs: elapsedSince(_initStart))

        // Create AI services (these are lightweight)
        StartupLogger.log("Creating AI services...")

        // Note: Test configuration will be set up asynchronously in initializeHeavyServices

        let aiServices = AIServicesFactory.makeAIServices(
            launchContext: launchContext,
            settingsStore: settingsStore,
            eventBus: _eventBus,
            activityCoordinator: _activityCoordinator
        )
        _aiService = aiServices.router
        StartupLogger.log("AI services done", elapsedMs: elapsedSince(_initStart))

        // Create conversation manager
        StartupLogger.log("Creating conversation manager...")

        _conversationManager = ConversationManager(
            dependencies: ConversationManager.Dependencies(
                services: ConversationManager.ServiceDependencies(
                    aiService: _aiService,
                    errorManager: errorManager,
                    fileSystemService: _fileSystemService,
                    fileEditorService: _fileEditorService,
                    activityCoordinator: _activityCoordinator
                ),
                environment: ConversationManager.EnvironmentDependencies(
                    workspaceService: _workspaceService,
                    eventBus: _eventBus,
                    projectRoot: nil,
                    codebaseIndex: nil
                )
            )
        )
        StartupLogger.log("Conversation manager done", elapsedMs: elapsedSince(_initStart))

        // Create project coordinator
        StartupLogger.log("Creating project coordinator...")

        let projectCoordinator = ProjectCoordinator(
            aiService: _aiService,
            errorManager: errorManager,
            eventBus: _eventBus,
            conversationManager: _conversationManager
        )
        _projectCoordinator = projectCoordinator
        _lineCompletionEngine = AIServicesFactory.makeLineCompletionEngine(
            aiServices: aiServices
        )

        StartupLogger.log("Project coordinator done", elapsedMs: elapsedSince(_initStart))

        StartupLogger.log("DependencyContainer.init END total", elapsedMs: elapsedSince(_initStart))

        // DO NOT set isInitialized here. Wait for heavy services background task to reach a stable "Medium" point.
        self.initializationStatus = "Starting heavy services..."

        // Defer truly heavy initialization to background - MUST use detached to escape @MainActor
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.initializeHeavyServices(launchContext: launchContext)
        }
    }

    /// Initialize heavy services asynchronously (database, embedding models, etc.)
    nonisolated private func initializeHeavyServices(launchContext: AppLaunchContext) async {
        let heavyStart = Date()

        if launchContext.disableHeavyInit {
            await MainActor.run {
                self.isInitialized = true
                self.initializationStatus = "Ready (heavy init disabled)"
            }
            return
        }

        // Small delay to let UI render first
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms
        
        // Note: Test configuration is set up by individual tests in their setUp methods

        // Safely access currentDirectory from Main Actor
        let projectRoot = await MainActor.run { _workspaceService.currentDirectory }

        if !launchContext.isTesting, let root = projectRoot {

            // Setup diagnostics logger with project root
            await DiagnosticsLogger.shared.setup(projectRoot: root)
            await UIRenderDiagnostics.shared.setup(projectRoot: root)

            await DiagnosticsLogger.shared.logEvent(
                .serviceInitStart, name: "project-configure", metadata: ["projectRoot": root.path])

            // Update conversation manager with project root - safe via MainActor hop
            await MainActor.run {
                _conversationManager.updateProjectRoot(root)
            }

            // Configure project asynchronously
            let isInitialized = await MainActor.run {
                _projectCoordinator.currentProjectRoot == root
                    && _projectCoordinator.codebaseIndex != nil
            }

            if !isInitialized {
                let configStart = Date()
                await MainActor.run {
                    self.initializationStatus = "Configuring project..."
                    _projectCoordinator.configureProject(root: root)
                }

                // Wait for project configuration to complete
                await _projectCoordinator.waitForInitialization()
            }

            await MainActor.run {
                _unifiedLintingFramework.runProjectScanIfNeeded()
            }

            // Initialize vector store for RAG. The FAISS index MUST match the
            // embedding model's real output dimension — the factory silently
            // falls back to other bundled models (768/1024-dim) if the
            // preferred one fails to load, which previously produced a
            // permanently empty store with zero diagnostics.
            let eventBus = await MainActor.run { _eventBus }
            let embedder = MemoryEmbeddingGeneratorFactory.makeBestAvailable()
            await MainActor.run { self._embedder = embedder }

            var cfg = VectorStoreConfiguration.default(basePath: root)
            if let embedder = embedder as? CoreMLTextEmbeddingGenerator,
               embedder.embeddingDim != cfg.dimensions {
                cfg = VectorStoreConfiguration(
                    storePath: cfg.storePath,
                    dimensions: embedder.embeddingDim,
                    factoryString: cfg.factoryString,
                    embeddingModel: embedder.modelIdentifier
                )
                await IndexLogger.shared.log(
                    "Vector store recreated with embedder dimension \(embedder.embeddingDim) (model: \(embedder.modelIdentifier))"
                )
            }

            let resolvedConfig = cfg
            let service: VectorStoreService?
            do {
                service = try await withTimeout(seconds: 15) {
                    await Task { VectorStoreService.create(with: resolvedConfig) }.value
                }
            } catch {
                service = nil
            }
            if let service {
                var vsLoadError: String? = nil
                do {
                    try await withTimeout(seconds: 15) {
                        try await service.load()
                    }
                } catch {
                    vsLoadError = error.localizedDescription
                }
                // Set service reference so polling fallback can find it immediately
                await MainActor.run {
                    _vectorStoreService = service
                    _conversationManager.updateVectorStoreService(service)
                }
                // Then publish status — polling will catch it even if event is lost
                if vsLoadError != nil {
                    eventBus.publish(VectorStoreStatusChangedEvent(entryCount: 0, isLoaded: true, isError: true))
                } else {
                    let count = await service.entryCount
                    eventBus.publish(VectorStoreStatusChangedEvent(entryCount: count, isLoaded: true))
                }
            } else {
                await MainActor.run {
                    _vectorStoreService = nil
                }
            }


            // Wire continuous embedding (only if vector store is available).
            // RETAINED on self — the coordinator was previously a local `let`,
            // so it deallocated at scope exit, its subscriptions cancelled, and
            // event-driven RAG ingestion never ran during a session.
            if let service {
                let embeddingCoordinator = VectorStoreEmbeddingCoordinator(
                    vectorStoreService: service,
                    eventBus: eventBus,
                    embedder: embedder ?? NullEmbeddingGenerator()
                )
                await embeddingCoordinator.start()
                await MainActor.run { self._embeddingCoordinator = embeddingCoordinator }
            }

            // Inject embedder into conversation manager for RAG
            await MainActor.run {
                _conversationManager.updateEmbedder(embedder)
            }

            // Wire event-driven logging coordinator
            let logCoordinator = LogCoordinator(projectRoot: root, eventBus: eventBus)
            logCoordinator.start()

            // Defer conversation ingestion to background — don't block startup
            Task.detached(priority: .utility) { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s cooloff for indexer to start first
                await self?.ingestConversations(service: service, projectRoot: root, eventBus: eventBus, embedder: embedder)
            }
        }

        await MainActor.run {
            self.isInitialized = true
            self.initializationStatus = "Ready"
        }

        let heavyDuration = Date().timeIntervalSince(heavyStart) * 1000

        await DiagnosticsLogger.shared.logEvent(
            .serviceInitEnd, name: "heavy-services",
            metadata: [
                "totalDurationMs": String(format: "%.2f", heavyDuration)
            ])

        // Check if FIM completion model is installed; prompt user to download if not
        if !launchContext.isTesting {
            await checkFIMCompletionModel(eventBus: await MainActor.run { _eventBus })
        }
    }

    /// Checks whether the FIM completion model is installed and prompts the user
    /// to download it if missing. Runs after heavy services are ready.
    nonisolated private func checkFIMCompletionModel(eventBus: EventBusProtocol) async {
        let model = LocalModelCatalog.fimModel

        guard !LocalModelFileStore.isModelInstalled(model) else {
            return
        }


        // Show modal dialog on main actor
        let shouldDownload = await MainActor.run { () -> Bool in
            let alert = NSAlert()
            alert.messageText = "No Completion Model Found"
            alert.informativeText = "Inline code completion requires the \(model.displayName) model. Download it now? (~750 MB)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Not Now")
            return alert.runModal() == .alertFirstButtonReturn
        }

        guard shouldDownload else {
            return
        }

        let downloader = LocalModelDownloader()

        do {
            try await downloader.download(model: model) { progress in
                let fraction = progress.fractionCompleted
                eventBus.publish(ModelDownloadProgressEvent(
                    fractionCompleted: fraction,
                    currentFileName: progress.currentFileName
                ))
                if fraction >= 1.0 {
                    eventBus.publish(ModelDownloadCompletedEvent(
                        modelId: model.id,
                        displayName: model.displayName
                    ))
                }
            }

            // Final completion event in case the last progress callback didn't fire at 1.0
            eventBus.publish(ModelDownloadCompletedEvent(
                modelId: model.id,
                displayName: model.displayName
            ))

            // Show completion alert
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Completion Now Available"
                alert.informativeText = "The \(model.displayName) model has been downloaded. Inline code completion is ready to use."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }

        } catch {
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Download Failed"
                alert.informativeText = "Could not download the completion model: \(error.localizedDescription). You can retry from Settings > Local Models."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    // MARK: - Public Accessors

    /// Error manager instance
    var errorManager: any ErrorManagerProtocol {
        return _errorManager
    }

    /// UI service instance
    var uiService: any UIServiceProtocol {
        return _uiService
    }

    /// Workspace service instance
    var workspaceService: any WorkspaceServiceProtocol {
        return _workspaceService
    }

    var eventBus: any EventBusProtocol {
        return _eventBus
    }

    var languageModuleManager: LanguageModuleManager {
        return _languageModuleManager
    }

    var commandRegistry: CommandRegistry {
        return _commandRegistry
    }

    var uiRegistry: UIRegistry {
        return _uiRegistry
    }

    var diagnosticsStore: DiagnosticsStore {
        return _diagnosticsStore
    }

    /// File editor service instance
    var fileEditorService: any FileEditorServiceProtocol {
        return _fileEditorService
    }

    /// File system service instance
    var fileSystemService: FileSystemService {
        return _fileSystemService
    }

    /// File dialog service instance
    var fileDialogService: any FileDialogServiceProtocol {
        return _fileDialogService
    }

    var windowProvider: WindowProvider {
        return _windowProvider
    }

    /// AI service instance
    var aiService: any AIService {
        return _aiService
    }

    /// Conversation manager instance
    var conversationManager: ConversationManager {
        return _conversationManager
    }

    /// Project coordinator instance
    var projectCoordinator: ProjectCoordinator {
        return _projectCoordinator
    }

    /// Codebase index instance (proxied through coordinator)
    var codebaseIndex: CodebaseIndexProtocol? {
        return _projectCoordinator.codebaseIndex
    }

    var isCodebaseIndexEnabled: Bool {
        return settingsStore.bool(
            forKey: AppConstants.Storage.codebaseIndexEnabledKey, default: true)
    }

    func setCodebaseIndexEnabled(_ enabled: Bool) {
        _projectCoordinator.setIndexEnabled(enabled)
    }

    func reindexProjectNow() {
        _projectCoordinator.rebuildIndex(overwriteDB: true)
    }

    func rebuildVectorStore() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let (service, projectRoot, eventBus, embedder) = await MainActor.run { () -> (VectorStoreService?, URL?, EventBusProtocol?, (any MemoryEmbeddingGenerating)?) in
                guard let self else { return (nil, nil, nil, nil) }
                if let existing = self._vectorStoreService { return (existing, self._workspaceService.currentDirectory, self._eventBus, self._embedder) }
                guard let root = self._workspaceService.currentDirectory else { return (nil, nil, nil, nil) }
                let cfg = VectorStoreConfiguration.default(basePath: root)
                let freshService = VectorStoreService.create(with: cfg)
                self._vectorStoreService = freshService
                self._conversationManager.updateVectorStoreService(freshService)
                return (freshService, root, self._eventBus, self._embedder)
            }
            guard let service, let projectRoot, let eventBus else {
                return
            }
            // Without an embedding model the rebuild would WIPE the store and
            // rebuild nothing — refuse instead of destroying user RAG memory.
            guard let embedder else {
                eventBus.publish(VectorStoreStatusChangedEvent(entryCount: await service.entryCount, isLoaded: true, isError: true))
                await RAGTraceLogger.shared.log(type: "store.rebuild_skipped", data: [
                    "reason": "no embedding model available"
                ])
                return
            }
            await RAGTraceLogger.shared.log(type: "store.rebuild_start", data: [:])
            do {
                try await service.removeAll()
                try await service.save()
                await VectorStoreIngestionTracker.shared.clear()
                eventBus.publish(VectorStoreStatusChangedEvent(entryCount: 0, isLoaded: true, isError: false))
                await self?.ingestConversations(service: service, projectRoot: projectRoot, eventBus: eventBus, embedder: embedder)
                await RAGTraceLogger.shared.log(type: "store.rebuild_complete", data: ["entries": await service.entryCount])
            } catch {
                await RAGTraceLogger.shared.log(type: "store.rebuild_error", data: [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    func configureCodebaseIndex(projectRoot: URL) {
        _projectCoordinator.configureProject(root: projectRoot)
    }

    // MARK: - Factory Methods

    /// Creates a configured AppState instance
    func makeAppState() -> AppState {
        return AppState(
            errorManager: errorManager,
            uiService: uiService,
            workspaceService: workspaceService,
            fileEditorService: fileEditorService,
            conversationManager: conversationManager,
            fileDialogService: fileDialogService,
            fileSystemService: fileSystemService,
            eventBus: eventBus,
            commandRegistry: commandRegistry,
            uiRegistry: uiRegistry,
            diagnosticsStore: diagnosticsStore,
            lineCompletionEngine: _lineCompletionEngine,
            windowProvider: windowProvider,
            codebaseIndexProvider: { [weak self] in
                self?.codebaseIndex
            },
            configureCodebaseIndex: { [weak self] projectRoot in
                self?.configureCodebaseIndex(projectRoot: projectRoot)
            },
            setCodebaseIndexEnabled: { [weak self] enabled in
                self?.setCodebaseIndexEnabled(enabled)
            },
            reindexProjectNow: { [weak self] in
                self?.reindexProjectNow()
            },
            vectorStoreServiceProvider: { [weak self] in
                self?.vectorStoreService
            },
            rebuildVectorStore: { [weak self] in
                self?.rebuildVectorStore()
            },
            refreshRemoteAIAccountBalance: { [weak self] runId in
                guard let self else { return }
                await (self._aiService as? RemoteAIAccountStatusRefreshing)?.refreshAccountBalance(runId: runId)
            }
        )
    }

    /// Updates the AI service used by the application
    func updateAIService(_ newService: any AIService) {
        _aiService = newService
        // Update the existing conversation manager's AI service instead of creating a new one
        // to preserve loaded chat history
        _conversationManager.updateAIService(newService)
    }

    private nonisolated func ingestConversations(service: VectorStoreService?, projectRoot: URL, eventBus: EventBusProtocol, embedder: (any MemoryEmbeddingGenerating)?) async {
        guard let service else {
            return
        }
        let tracker = VectorStoreIngestionTracker.shared
        let convDir = projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
        let indexURL = convDir.appendingPathComponent("index.ndjson")

        guard let contents = try? String(contentsOf: indexURL, encoding: .utf8) else {
            let count = await service.entryCount
            eventBus.publish(VectorStoreStatusChangedEvent(entryCount: count, isLoaded: true))
            return
        }

        let lines = contents.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var toIngest: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(ConversationIndexEntry.self, from: data),
                  !(await tracker.isIngested(conversationId: entry.conversationId)) else { continue }
            toIngest.append(entry.conversationId)
        }

        guard !toIngest.isEmpty else {
            let count = await service.entryCount
            eventBus.publish(VectorStoreStatusChangedEvent(entryCount: count, isLoaded: true))
            return
        }

        // Bound per-launch ingestion: embedding every historical turn on every
        // launch competes with the indexer and FIM load for minutes. The most
        // recent conversations matter most; the rest lands on later launches.
        let perLaunchCap = 20
        if toIngest.count > perLaunchCap {
            toIngest = Array(toIngest.suffix(perLaunchCap))
        }

        await RAGTraceLogger.shared.log(type: "store.ingest_start", data: ["count": toIngest.count])
        eventBus.publish(VectorStoreIngestionProgressEvent(ingestedCount: 0, totalCount: toIngest.count))

        guard let embedder else {
            let count = await service.entryCount
            eventBus.publish(VectorStoreStatusChangedEvent(entryCount: count, isLoaded: true))
            eventBus.publish(VectorStoreIngestionProgressEvent(ingestedCount: toIngest.count, totalCount: toIngest.count))
            return
        }
        var ingested: Int = 0

        for convId in toIngest {
            let convURL = convDir
                .appendingPathComponent(convId, isDirectory: true)
                .appendingPathComponent("conversation.ndjson")
            guard let convData = try? String(contentsOf: convURL, encoding: .utf8) else {
                // Missing file — skip WITHOUT marking ingested so a later
                // launch retries it.
                continue
            }

            let eventLines = convData.components(separatedBy: .newlines).filter { !$0.isEmpty }
            var queryText: String?

            for eventLine in eventLines {
                guard let eventData = eventLine.data(using: .utf8),
                      let event = try? JSONDecoder().decode(ConversationLogEvent.self, from: eventData) else { continue }

                if event.type == "chat.user_message" {
                    queryText = extractString(from: event.data?["content"])
                } else if event.type == "chat.assistant_message" || event.type == "chat.response" {
                    if let q = queryText, let r = extractString(from: event.data?["content"]) {
                        let qVec = (try? await embedder.generateEmbedding(for: q)) ?? []
                        let rVec = (try? await embedder.generateEmbedding(for: r)) ?? []
                        if !qVec.isEmpty, !rVec.isEmpty {
                            let turn = VectorStoreService.ConversationTurn(
                                query: q, response: r,
                                source: "conversation", category: convId
                            )
                            try? await service.storeConversationTurn(turn: turn, queryVector: qVec, responseVector: rVec)
                        }
                    }
                    queryText = nil
                }
            }

            let totalEvents = eventLines.count
            await tracker.markIngested(conversationId: convId)
            ingested += 1
            eventBus.publish(VectorStoreIngestionProgressEvent(ingestedCount: ingested, totalCount: toIngest.count))
        }

        try? await service.save()
        let count = await service.entryCount
        eventBus.publish(VectorStoreStatusChangedEvent(entryCount: count, isLoaded: true))
        await RAGTraceLogger.shared.log(type: "store.ingest_complete", data: ["entries": count])
    }

    private nonisolated func extractString(from logValue: LogValue?) -> String? {
        guard case .string(let value) = logValue else { return nil }
        return value
    }

    // MARK: - Stored Services

    private let _errorManager: any ErrorManagerProtocol
    private let _eventBus: EventBus
    private let _commandRegistry: CommandRegistry
    private let _uiRegistry: UIRegistry
    private let _diagnosticsStore: DiagnosticsStore
    private let _uiService: any UIServiceProtocol
    private let _workspaceService: any WorkspaceServiceProtocol
    private let _fileEditorService: any FileEditorServiceProtocol
    private let _fileSystemService: FileSystemService
    private let _fileDialogService: any FileDialogServiceProtocol
    private let _windowProvider: WindowProvider
    private let _unifiedLintingFramework: UnifiedLintingFramework
    private let _languageModuleManager: LanguageModuleManager
    private var _aiService: any AIService
    private var _conversationManager: ConversationManager
    private var _projectCoordinator: ProjectCoordinator
    private let _lineCompletionEngine: LineCompletionEngine
    private let _activityCoordinator: any AgentActivityCoordinating
    private var _vectorStoreService: VectorStoreService?
    private var _embedder: (any MemoryEmbeddingGenerating)?
    private var _embeddingCoordinator: VectorStoreEmbeddingCoordinator?

    /// Persists vector-store state (index + metadata + id mapping) so RAG
    /// memory added during the session survives quit/crash.
    func persistVectorStore() {
        let service = _vectorStoreService
        Task {
            try? await service?.save()
        }
    }
    
    /// Accessor for activity coordinator (for integration with other services)
    var activityCoordinator: any AgentActivityCoordinating {
        return _activityCoordinator
    }
    
    /// Accessor for line completion engine (automatic single-line ghost)
    var lineCompletionEngine: LineCompletionEngine {
        return _lineCompletionEngine
    }

    /// Vector store service for RAG-based retrieval
    var vectorStoreService: VectorStoreService? {
        _vectorStoreService
    }
}

// MARK: - Testing Support

#if DEBUG
extension DependencyContainer {
    /// Create a container with mock services for testing
    static func makeTestContainer() -> DependencyContainer {
        return DependencyContainer()
    }
}
#endif
