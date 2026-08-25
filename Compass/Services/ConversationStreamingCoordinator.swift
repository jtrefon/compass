import Combine
import Foundation

/// Owns all streaming draft state and rendering for a conversation.
///
/// **Design rationale:**
/// - Extracts the 5 streaming properties + 4 subscriptions + 4 handlers that
///   previously lived in `ConversationManager` (832 lines). The manager now
///   holds only a single `streamingCoordinator` reference and forwards
///   `beginStreaming` / `reset` calls.
/// - `@MainActor` because `ChatHistoryCoordinator` and `StreamingOutputBuffer`
///   are main-actor confined and every event is delivered on main
///   (`EventBus.subscribe` does `receive(on: DispatchQueue.main)`).
/// - `providerIssue` is published here and observed by `ConversationManager`
///   so the manager's `@Published` stays the SwiftUI source of truth without
///   duplicating subscription logic.
@MainActor
final class ConversationStreamingCoordinator: ObservableObject {

    // MARK: - Published state observed by ConversationManager

    @Published private(set) var providerIssue: ConversationProviderIssueState?

    // MARK: - Streaming draft state

    private(set) var activeStreamingRunId: String?
    private(set) var draftAssistantMessageId: UUID?
    private var lastRenderedDraftContent: String = ""
    private var lastRenderedDraftReasoning: String = ""
    private let outputBuffer = StreamingOutputBuffer()

    // MARK: - Dependencies

    private let historyCoordinator: ChatHistoryCoordinator
    private let eventBus: any EventBusProtocol
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(historyCoordinator: ChatHistoryCoordinator, eventBus: any EventBusProtocol) {
        self.historyCoordinator = historyCoordinator
        self.eventBus = eventBus
        setupStreamingSubscriptions()
    }

    // MARK: - Public API used by ConversationManager

    /// Starts a new streaming draft for `runId`/`draftId`.
    func beginStreaming(runId: String, draftId: UUID, draftMessage: ChatMessage) {
        activeStreamingRunId = runId
        draftAssistantMessageId = draftId
        historyCoordinator.setDraft(draftMessage)
    }

    /// Clears all streaming state and the output buffer.
    func resetStreamingDraftState() {
        activeStreamingRunId = nil
        draftAssistantMessageId = nil
        lastRenderedDraftContent = ""
        lastRenderedDraftReasoning = ""
        outputBuffer.clear()
    }

    /// Resets the text buffer without clearing run state.
    /// Used when the local model tool loop needs fresh output.
    func clearStreamingText() {
        lastRenderedDraftContent = ""
        lastRenderedDraftReasoning = ""
        outputBuffer.clear()
    }

    /// Clears the provider issue banner.
    func clearProviderIssue() {
        providerIssue = nil
    }

    // MARK: - Private

    private func setupStreamingSubscriptions() {
        eventBus
            .subscribe(to: LocalModelStreamingChunkEvent.self) { [weak self] event in
                guard let self else { return }
                self.handleLocalModelStreamingChunk(event)
            }
            .store(in: &cancellables)

        eventBus
            .subscribe(to: LocalModelStreamingReasoningChunkEvent.self) { [weak self] event in
                guard let self else { return }
                self.handleLocalModelStreamingReasoningChunk(event)
            }
            .store(in: &cancellables)

        eventBus
            .subscribe(to: ProviderIssueStatusEvent.self) { [weak self] event in
                guard let self else { return }
                if event.statusKind == .resolved {
                    self.providerIssue = nil
                    return
                }
                self.providerIssue = ConversationProviderIssueState(
                    providerName: event.providerName,
                    issueType: self.providerIssueTypeLabel(for: event.statusKind),
                    statusCode: event.statusCode,
                    message: event.message,
                    cooldownUntil: event.cooldownUntil
                )
            }
            .store(in: &cancellables)

        eventBus
            .subscribe(to: OpenRouterUsageUpdatedEvent.self) { [weak self] event in
                guard let self else { return }
                self.handleOpenRouterUsageUpdated(event)
            }
            .store(in: &cancellables)
    }

    private func providerIssueTypeLabel(for statusKind: ProviderIssueStatusEvent.StatusKind) -> String {
        switch statusKind {
        case .resolved: return "Resolved"
        case .rateLimited: return "Rate limit"
        case .unavailable: return "Provider unavailable"
        case .authentication: return "Authentication"
        case .transport: return "Connection"
        case .networkOffline: return "Network offline"
        case .insufficientBalance: return "Insufficient balance"
        case .unknown: return "Provider issue"
        }
    }

    // MARK: - Streaming Rendering

    private func handleLocalModelStreamingChunk(_ event: LocalModelStreamingChunkEvent) {
        guard let runId = activeStreamingRunId, runId == event.runId else { return }
        guard let draftId = draftAssistantMessageId else { return }
        guard !event.chunk.isEmpty else { return }
        renderStreamingChunk(event.chunk, draftId: draftId)
    }

    private func handleLocalModelStreamingReasoningChunk(_ event: LocalModelStreamingReasoningChunkEvent) {
        guard let runId = activeStreamingRunId, runId == event.runId else { return }
        guard let draftId = draftAssistantMessageId else { return }
        guard !event.chunk.isEmpty else { return }
        renderStreamingReasoning(event.chunk, draftId: draftId)
    }

    private func renderStreamingChunk(_ chunk: String, draftId: UUID) {
        outputBuffer.appendContent(chunk)
        outputBuffer.flushClassification()
        let renderContent = outputBuffer.hasContent ? outputBuffer.content : ""
        guard renderContent != lastRenderedDraftContent else { return }
        lastRenderedDraftContent = renderContent
        let renderReasoning: String? = outputBuffer.hasReasoning ? outputBuffer.reasoning : nil
        historyCoordinator.setDraft(
            ChatMessage(
                id: draftId,
                role: .assistant,
                content: renderContent,
                timestamp: historyCoordinator.getDraftMessage(id: draftId)?.timestamp ?? Date(),
                context: ChatMessageContentContext(reasoning: renderReasoning),
                isDraft: true
            )
        )
    }

    private func renderStreamingReasoning(_ chunk: String, draftId: UUID) {
        outputBuffer.appendReasoning(chunk)
        let renderReasoning: String? = outputBuffer.hasReasoning ? outputBuffer.reasoning : nil
        guard renderReasoning != lastRenderedDraftReasoning else { return }
        lastRenderedDraftReasoning = renderReasoning ?? ""
        let renderContent = outputBuffer.hasContent ? outputBuffer.content : ""
        historyCoordinator.setDraft(
            ChatMessage(
                id: draftId,
                role: .assistant,
                content: renderContent,
                timestamp: historyCoordinator.getDraftMessage(id: draftId)?.timestamp ?? Date(),
                context: ChatMessageContentContext(reasoning: renderReasoning),
                isDraft: true
            )
        )
    }

    private func handleOpenRouterUsageUpdated(_ event: OpenRouterUsageUpdatedEvent) {
        guard let runId = event.runId, runId == activeStreamingRunId else { return }
        guard let draftId = draftAssistantMessageId else { return }
        guard let draftMessage = historyCoordinator.getDraftMessage(id: draftId) else { return }

        historyCoordinator.setDraft(
            ChatMessage(
                id: draftMessage.id,
                role: draftMessage.role,
                content: draftMessage.content,
                timestamp: draftMessage.timestamp,
                context: ChatMessageContentContext(
                    reasoning: draftMessage.reasoning,
                    codeContext: draftMessage.codeContext
                ),
                billing: ChatMessageBillingContext(
                    requestCostMicrodollars: event.usage.costMicrodollars,
                    providerName: event.providerName,
                    modelId: event.modelId,
                    runId: event.runId
                ),
                tool: ChatMessageToolContext(
                    toolName: draftMessage.toolName,
                    toolStatus: draftMessage.toolStatus,
                    target: ToolInvocationTarget(
                        targetFile: draftMessage.targetFile,
                        toolCallId: draftMessage.toolCallId
                    ),
                    toolCalls: draftMessage.toolCalls ?? []
                ),
                isDraft: draftMessage.isDraft
            )
        )
    }
}
