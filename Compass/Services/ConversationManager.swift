//
//  ConversationManager.swift
//  Compass
//
//  Created by AI Assistant on 25/08/2025.
//

import Foundation
import Combine
import SwiftUI

// MARK: - ConversationManager

@MainActor
final class ConversationManager: ObservableObject, ConversationManagerProtocol {

    // MARK: - Nested Types

    struct Dependencies {
        let services: ServiceDependencies
        let environment: EnvironmentDependencies
    }

    struct ServiceDependencies {
        let aiService: AIService
        let errorManager: any ErrorManagerProtocol
        let fileSystemService: FileSystemService
        let fileEditorService: (any FileEditorServiceProtocol)?
        let activityCoordinator: (any AgentActivityCoordinating)?
    }

    struct EnvironmentDependencies {
        let workspaceService: any WorkspaceServiceProtocol
        let eventBus: any EventBusProtocol
        let projectRoot: URL?
        let codebaseIndex: CodebaseIndexProtocol?
    }

    private struct UserMessageContext {
        let text: String
        let hasSelectionContext: Bool
        let message: ChatMessage
    }

    /// Thread-safe holder for the cancelled tool-call ids. The graph's send
    /// pipeline reads it from arbitrary executors via a `@Sendable` closure,
    /// while mutations happen on the main actor.
    private final class CancelledToolCallIDsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []

        func mutate(_ body: (inout Set<String>) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&ids)
        }

        var snapshot: Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return ids
        }
    }

    // MARK: - Published State

    @Published var currentInput: String = ""
    @Published var isSending: Bool = false
    @Published var error: String?
    @Published var currentMode: AIMode = .chat
    @Published var cancelledToolCallIds: Set<String> = []
    private let cancelledToolCallIDsBox = CancelledToolCallIDsBox()
    @Published private(set) var conversationTabs: [ConversationTabItem] = []
    @Published private(set) var closedConversations: [ClosedConversation] = []
    @Published private(set) var providerIssue: ConversationProviderIssueState?
    @Published private(set) var messages: [ChatMessage] = []

    // MARK: - Dependencies

    private let historyCoordinator: ChatHistoryCoordinator
    private let toolExecutor: AIToolExecutor
    private let toolExecutionCoordinator: ToolExecutionCoordinator
    private var aiService: AIService
    private let aiInteractionCoordinator: AIInteractionCoordinator
    private let sendCoordinator: ConversationSendCoordinator
    private let errorManager: any ErrorManagerProtocol
    private let fileSystemService: FileSystemService
    private weak var fileEditorService: (any FileEditorServiceProtocol)?
    private let workspaceService: any WorkspaceServiceProtocol
    private let eventBus: any EventBusProtocol
    private var codebaseIndex: (any CodebaseIndexProtocol)?
    private var projectRoot: URL
    private let conversationLogger: ConversationLogger
    private let sessionManager: SessionManager
    private let sessionCoordinator: ConversationSessionCoordinator
    private let lifecycleCoordinator: ConversationLifecycleCoordinator
    private let settingsStore = SettingsStore(userDefaults: AppRuntimeEnvironment.userDefaults)
    private let activityCoordinator: AgentActivityCoordinating?
    private lazy var toolProvider = ConversationToolProvider(
        fileSystemService: fileSystemService,
        eventBus: eventBus,
        vectorStoreService: nil,
        embedder: nil,
        codebaseIndexProvider: { [weak self] in self?.codebaseIndex },
        projectRootProvider: { [weak self] in self?.projectRoot }
    )
    private var cancellables = Set<AnyCancellable>()
    private let streamingCoordinator: ConversationStreamingCoordinator
    private var activeSendTask: Task<Void, Never>?
    private var activeRunCounter = 0

    // Streaming state now owned by ConversationStreamingCoordinator.
    // Kept as computed forwards for call sites that read the draft/run id.
    private var activeStreamingRunId: String? { streamingCoordinator.activeStreamingRunId }
    private var draftAssistantMessageId: UUID? { streamingCoordinator.draftAssistantMessageId }

    // MARK: - Computed Properties

    var currentConversationId: String {
        sessionManager.selectedId
    }

    private var conversationId: String {
        sessionManager.selectedId
    }

    private var pathValidator: PathValidator {
        workspaceService.makePathValidator(projectRoot: projectRoot)
    }

    private var availableTools: [AITool] {
        toolProvider.availableTools(mode: currentMode, pathValidator: pathValidator)
    }

    /// Single routing decision: offline mode = local MLX, else remote. This
    /// is the ONLY place the local/remote split is resolved for sends.
    private var usesLocalModel: Bool {
        settingsStore.bool(forKey: LocalModelSettingsKeys.offlineModeEnabled, default: false)
    }

    // MARK: - Initialization

    init(dependencies: Dependencies) {
        self.aiService = dependencies.services.aiService
        self.errorManager = dependencies.services.errorManager
        self.fileSystemService = dependencies.services.fileSystemService
        self.fileEditorService = dependencies.services.fileEditorService
        self.activityCoordinator = dependencies.services.activityCoordinator
        self.workspaceService = dependencies.environment.workspaceService
        self.eventBus = dependencies.environment.eventBus
        let root = dependencies.environment.projectRoot ?? FileManager.default.temporaryDirectory
        self.projectRoot = root
        self.codebaseIndex = dependencies.environment.codebaseIndex

        self.aiInteractionCoordinator = AIInteractionCoordinator(
            aiService: dependencies.services.aiService,
            eventBus: dependencies.environment.eventBus
        )

        self.historyCoordinator = ChatHistoryCoordinator(eventBus: dependencies.environment.eventBus)
        self.sessionManager = SessionManager(
            historyCoordinator: historyCoordinator,
            projectRoot: root
        )
        self.streamingCoordinator = ConversationStreamingCoordinator(
            historyCoordinator: historyCoordinator,
            eventBus: dependencies.environment.eventBus
        )
        self.sessionCoordinator = ConversationSessionCoordinator(
            sessionManager: sessionManager,
            historyCoordinator: historyCoordinator
        )
        let fileEditorServiceProvider = fileEditorService
        self.toolExecutor = AIToolExecutor(
            fileSystemService: dependencies.services.fileSystemService,
            errorManager: dependencies.services.errorManager,
            projectRoot: root,
            eventBus: dependencies.environment.eventBus,
            defaultFilePathProvider: { [weak fileEditorServiceProvider] in
                fileEditorServiceProvider?.selectedFile
            },
            activityCoordinator: dependencies.services.activityCoordinator
        )

        self.toolExecutionCoordinator = ToolExecutionCoordinator(executor: toolExecutor)

        self.sendCoordinator = ConversationSendCoordinator(
            historyCoordinator: historyCoordinator,
            aiInteractionCoordinator: aiInteractionCoordinator,
            toolExecutionCoordinator: toolExecutionCoordinator
        )
        self.toolExecutionCoordinator.setCancellationProvider { [box = self.cancelledToolCallIDsBox] in
            box.snapshot
        }

        self.conversationLogger = ConversationLogger()
        self.lifecycleCoordinator = ConversationLifecycleCoordinator(
            conversationLogger: conversationLogger,
            activityCoordinator: dependencies.services.activityCoordinator
        )

        // Wire up streaming reset after all properties are initialized
        self.sendCoordinator.clearStreamingBuffer = { [weak self] in
            self?.clearStreamingText()
        }

        lifecycleCoordinator.initializeLogging(root: root, eventBus: eventBus)
        setupObservation()
        lifecycleCoordinator.observeIsSending($isSending)
        observeStreamingCoordinator()
        observeSessionCoordinator()
        lifecycleCoordinator.startTraceLogging(root: root, currentMode: currentMode)
        lifecycleCoordinator.configureLoggingStores(root: root)
        // Restore the last session's state (messages, mode, input)
        // so the app picks up where it left off on relaunch.
        // (§Fix: session persistence regression — restoreSession was never
        // called during app startup after the Conversation/ stack deletion.)
        restoreSession(sessionManager.selectedId)
    }

    deinit {
        activeSendTask?.cancel()
    }

    // MARK: - Session Management

    private func observeSessionCoordinator() {
        sessionCoordinator.$conversationTabs
            .sink { [weak self] tabs in self?.conversationTabs = tabs }
            .store(in: &cancellables)
        sessionCoordinator.$closedConversations
            .sink { [weak self] closed in self?.closedConversations = closed }
            .store(in: &cancellables)
        sessionCoordinator.$messages
            .sink { [weak self] msgs in self?.messages = msgs }
            .store(in: &cancellables)
        sessionCoordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func saveCurrentSessionSnapshot() {
        sessionCoordinator.saveCurrentSnapshot(input: currentInput, mode: currentMode)
    }

    private func updateCancelledToolCallIds(_ mutate: (inout Set<String>) -> Void) {
        cancelledToolCallIDsBox.mutate(mutate)
        mutate(&cancelledToolCallIds)
    }

    private func restoreSession(_ sessionId: String) {
        updateCancelledToolCallIds { $0.removeAll() }
        sessionCoordinator.restoreSession(sessionId, input: &currentInput, mode: &currentMode)
    }

    private func observeStreamingCoordinator() {
        streamingCoordinator.$providerIssue
            .sink { [weak self] issue in self?.providerIssue = issue }
            .store(in: &cancellables)
        streamingCoordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Observation

    private func setupObservation() {
        historyCoordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Dependency Updates

    func updateAIService(_ newService: AIService) {
        self.aiService = newService
        aiInteractionCoordinator.updateAIService(newService)
    }

    func updateCodebaseIndex(_ newIndex: CodebaseIndexProtocol?) {
        codebaseIndex = newIndex
    }

    func updateVectorStoreService(_ service: VectorStoreService?) {
        toolProvider.updateVectorStoreService(service)
    }

    func updateEmbedder(_ embedder: (any MemoryEmbeddingGenerating)?) {
        toolProvider.updateEmbedder(embedder)
    }

    func updateProjectRoot(_ newRoot: URL) {
        if projectRoot.standardizedFileURL == newRoot.standardizedFileURL {
            return
        }

        projectRoot = newRoot
        toolExecutor.updateProjectRoot(newRoot)
        lifecycleCoordinator.configureLoggingStores(root: newRoot)

        saveCurrentSessionSnapshot()

        clearConversation()

        sessionCoordinator.updateProjectRoot(newRoot, input: &currentInput, mode: &currentMode)

        lifecycleCoordinator.initializeLogging(root: newRoot, eventBus: eventBus)
        lifecycleCoordinator.startTraceLogging(root: newRoot, currentMode: currentMode)
        conversationLogger.logConversationStart(
            conversationId: self.conversationId,
            mode: self.currentMode.rawValue,
            projectRootPath: newRoot.path
        )
    }

    // MARK: - Send Pipeline

    func sendMessage() {
        sendMessage(context: nil)
    }

    func sendMessage(context: String? = nil) {
        guard !isSending else { return }
        guard !currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Fresh run = fresh per-call cancellation state.
        updateCancelledToolCallIds { $0.removeAll() }
        let userContext = buildUserMessageContext(context: context)
        logUserMessage(userContext)
        historyCoordinator.appendSync(userContext.message)
        if historyCoordinator.conversationEnvelope.subject.isEmpty {
            let preview = String(userContext.message.content.prefix(60))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty {
                historyCoordinator.updateSubject(preview)
                sessionManager.saveSnapshot(input: currentInput, mode: currentMode)
            }
        }
        publishContextEvent()
        resetInputState()
        startSendTask(userContext: userContext, explicitContext: context)
    }

    private func buildUserMessageContext(context: String?) -> UserMessageContext {
        let userMessageText = currentInput
        let hasSelectionContext = (context?.isEmpty == false)
        let userMessage = ChatMessage(
            role: .user,
            content: currentInput,
            context: ChatMessageContentContext(codeContext: context)
        )
        return UserMessageContext(
            text: userMessageText,
            hasSelectionContext: hasSelectionContext,
            message: userMessage
        )
    }

    private func logUserMessage(_ context: UserMessageContext) {
        conversationLogger.logUserMessage(
            ConversationUserMessageLogContext(
                identity: ConversationUserMessageLogContext.Identity(
                    conversationId: conversationId,
                    projectRootPath: projectRoot.path
                ),
                details: ConversationUserMessageLogContext.MessageDetails(
                    text: context.text,
                    mode: currentMode.rawValue,
                    hasSelectionContext: context.hasSelectionContext
                )
            )
        )
    }

    private func resetInputState() {
        currentInput = ""
        isSending = true
        error = nil
        providerIssue = nil
    }

    private func publishContextEvent() {
        let msgs = historyCoordinator.messages
        let totalChars = msgs.reduce(0) { $0 + $1.content.count }
        let contextWindowChars: Int?
        if usesLocalModel {
            // The local gauge must reflect the LOCAL model's window — the
            // OpenRouter override / 262_000 fallback is the cloud ceiling and
            // is meaningless for the local path (a 64K toggle was displayed as
            // 262K because this branch was never taken).
            let stored = settingsStore.integer(forKey: LocalModelSettingsKeys.contextLength)
            let windowTokens = min(
                stored > 0 ? stored : LocalModelCatalog.chatModel.defaultContextLength,
                LocalModelCatalog.chatModel.maxContextLength
            )
            contextWindowChars = windowTokens > 0 ? windowTokens * 4 : nil
        } else {
            let ceOverride = CustomEndpointSettingsStore().load(includeApiKey: false).contextOverride
            let windowTokens: Int = ceOverride > 0 ? ceOverride : 262_000
            contextWindowChars = windowTokens > 0 ? windowTokens * 4 : nil
        }
        let kvCache4BitEnabled = settingsStore.bool(forKey: LocalModelSettingsKeys.kvCache4BitEnabled, default: false)
        let compressionRatio: Double? = (usesLocalModel && kvCache4BitEnabled) ? 8.0 : nil
        eventBus.publish(ConversationContextEvent(
            totalCharCount: totalChars,
            messageCount: msgs.count,
            contextWindowChars: contextWindowChars,
            compressionRatio: compressionRatio
        ))
    }

    // MARK: - State Reset — forwarded to ConversationStreamingCoordinator

    private func resetStreamingDraftState() {
        streamingCoordinator.resetStreamingDraftState()
    }

    /// Resets the streaming text buffer without clearing run state.
    /// Used when the local model tool loop needs to start fresh output.
    @MainActor
    func clearStreamingText() {
        streamingCoordinator.clearStreamingText()
    }

    private func resetConversationInteractionState() {
        streamingCoordinator.resetStreamingDraftState()
        streamingCoordinator.clearProviderIssue()
        isSending = false
        error = nil
        providerIssue = nil
    }

    private func cancelActiveSendTask() {
        activeSendTask?.cancel()
        activeSendTask = nil
    }

    private func startSendTask(userContext: UserMessageContext, explicitContext: String?) {
        cancelActiveSendTask()
        activeRunCounter += 1
        let runSequence = activeRunCounter
        activeSendTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                // Only tear down if this task is still the current run — a
                // cancelled predecessor must never clobber a newer run.
                if self.activeRunCounter == runSequence {
                    self.activeSendTask = nil
                    if self.isSending {
                        self.isSending = false
                    }
                }
            }

            let runId = UUID().uuidString

            // Create a draft message that will be updated during streaming
            let draftMessage = ChatMessage(
                role: .assistant,
                content: "",
                isDraft: true
            )
            self.streamingCoordinator.beginStreaming(runId: runId, draftId: draftMessage.id, draftMessage: draftMessage)

            let tools = self.currentMode.allowedTools(from: self.availableTools)

            do {
                conversationLogger.logAIRequestStart(
                    mode: self.currentMode.rawValue,
                    historyCount: self.messages.count
                )

                // All modes route through the same graph architecture
                // (see ConversationSendCoordinator). Mode differences are
                // the toolsets selected by AIMode.allowedTools(from:).
                // Local requests preserve the message prefix untouched so the
                // MLX KV cache stays reusable; cloud requests don't.
                let preservesCache = self.usesLocalModel
                try await self.sendCoordinator.send(
                    SendRequest(
                        userInput: userContext.text,
                        mode: self.currentMode,
                        projectRoot: self.projectRoot,
                        conversationId: self.conversationId,
                        runId: runId,
                        availableTools: tools,
                        draftAssistantMessageId: self.draftAssistantMessageId,
                        usesLocalModel: self.usesLocalModel,
                        preservesCache: preservesCache
                    )
                )

                self.historyCoordinator.clearDraft()
                self.resetStreamingDraftState()
                self.streamingCoordinator.clearProviderIssue()
                self.providerIssue = nil
                self.isSending = false
                self.eventBus.publish(ConversationRunCompletedEvent(runId: runId))
            } catch {
                // Clean up draft message on error
                self.historyCoordinator.clearDraft()
                self.resetStreamingDraftState()
                if error is CancellationError || Task.isCancelled || self.isLikelyCancellation(error) {
                    // Only the current run may clear the sending state — a stale
                    // cancelled task must not flip isSending while a newer run
                    // is in flight (re-entrancy window).
                    if self.activeRunCounter == runSequence {
                        self.isSending = false
                    }
                    return
                }
                handleSendFailure(error)
            }
        }
    }

    private func handleSendFailure(_ error: Error) {
        conversationLogger.logChatError(
            conversationId: conversationId,
            errorDescription: error.localizedDescription
        )
        Task { @MainActor in
            errorManager.handle(.aiServiceError(error.localizedDescription))
            self.error = "Failed to get AI response: \(error.localizedDescription)"
            isSending = false
        }
    }

    private func isLikelyCancellation(_ error: Error) -> Bool {
        // Typed checks first — the string fallback below must not swallow real
        // failures whose description merely mentions "cancelled".
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        let normalized = String(describing: error).lowercased()
        return normalized.contains("request cancelled")
            || normalized.contains("request canceled")
    }

    // MARK: - Conversation Lifecycle

    func clearConversation() {
        cancelActiveSendTask()
        resetConversationInteractionState()
        currentInput = ""
        sessionCoordinator.clearHistory()
        updateCancelledToolCallIds { $0.removeAll() }
    }

    func startNewConversation() {
        cancelActiveSendTask()
        resetConversationInteractionState()
        saveCurrentSessionSnapshot()
        currentInput = ""
        sessionCoordinator.clearHistory()

        let oldConversationId = sessionManager.selectedId
        let newConversationId = sessionCoordinator.startNew(
            input: &currentInput,
            mode: &currentMode
        )
        updateCancelledToolCallIds { $0.removeAll() }

        conversationLogger.logConversationStart(
            conversationId: newConversationId,
            mode: self.currentMode.rawValue,
            projectRootPath: self.projectRoot.path,
            previousConversationId: oldConversationId
        )
    }

    func switchConversation(to id: String) {
        cancelActiveSendTask()
        resetConversationInteractionState()
        saveCurrentSessionSnapshot()
        guard sessionCoordinator.switchTo(
            id: id,
            input: &currentInput,
            mode: &currentMode
        ) else { return }
    }

    func closeConversation(id: String) {
        cancelActiveSendTask()
        saveCurrentSessionSnapshot()
        _ = sessionCoordinator.close(
            id: id,
            input: &currentInput,
            mode: &currentMode
        )
    }

    /// Reopens a previously closed conversation so its history is available again as a tab.
    func recoverConversation(id: String) {
        cancelActiveSendTask()
        resetConversationInteractionState()
        saveCurrentSessionSnapshot()
        _ = sessionCoordinator.recover(
            id: id,
            input: &currentInput,
            mode: &currentMode
        )
    }

    /// Permanently removes a closed conversation from the recovery dropdown.
    func discardClosedConversation(id: String) {
        sessionCoordinator.discardClosed(id: id)
    }

    func stopGeneration() {
        guard isSending else { return }
        cancelActiveSendTask()
        resetStreamingDraftState()
        // Clean up any stale draft message from the history coordinator
        // so the next sendMessage() starts with a clean slate
        historyCoordinator.clearDraft()
        streamingCoordinator.clearProviderIssue()
        // Keep cancelledToolCallIds — the executor skips these before running;
        // the task cancellation itself aborts the remaining loop (see
        // ToolExecutionCoordinator). Wiping them here made Stop unable to stop.
        isSending = false
        providerIssue = nil
    }
}
