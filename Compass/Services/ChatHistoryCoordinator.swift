import Combine
import Foundation

public struct ConversationEnvelope: Sendable {
    public let id: UUID
    public var subject: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), subject: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.subject = subject
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Public API to the conversation context. `_committed` is the single source
/// of truth — append-only, MainActor-confined. No message is ever removed,
/// replaced, or reordered.
@MainActor
final class ChatHistoryCoordinator: ObservableObject {
    // MARK: - Committed history (single source of truth)

    private var _committed: [ChatMessage] = []

    /// The full, unaltered conversation chain. Every message ever pushed, in order.
    /// No rolling, no projection, no dedup. This is what the model sees.
    var allMessages: [ChatMessage] { _committed }

    // MARK: - Ephemeral UI state (NOT part of the chain)

    private var draft: ChatMessage?
    private var liveToolStatus: [String: ToolExecutionStatus] = [:]
    private var liveToolMessages: [String: ChatMessage] = [:]

    /// Display composition (committed + draft + live tool-status overlay).
    /// SwiftUI observes this. Never sent to the model — use `allMessages` for that.
    @Published private(set) var messages: [ChatMessage] = []

    // MARK: - Envelope

    private var envelope: ConversationEnvelope
    var currentConversationId: String { envelope.id.uuidString }
    var conversationEnvelope: ConversationEnvelope { envelope }

    var eventBus: (any EventBusProtocol)?

    // MARK: - Init

    init(projectRoot: URL? = nil, envelope: ConversationEnvelope = ConversationEnvelope(), eventBus: (any EventBusProtocol)? = nil) {
        self.envelope = envelope
        self.eventBus = eventBus
    }

    // MARK: - Append-only writes

    /// Push a message onto the committed history. This is the canonical mutation.
    func append(_ message: ChatMessage) async {
        syncAppend(message)
    }

    /// Synchronous append for use when an async call is impossible
    /// (SwiftUI button handler, etc.).
    func appendSync(_ message: ChatMessage) {
        syncAppend(message)
    }

    private func syncAppend(_ message: ChatMessage) {
        if message.isDraft {
            draft = message
        }
        _committed.append(message)
        envelope.updatedAt = Date()
        recompose()
    }

    // MARK: - Draft

    /// Replaces the in-flight draft with its final content and moves it into
    /// committed history. Idempotent: if the draft id is not present in the
    /// committed array (a draft that was never appended), the message is
    /// appended instead. Never duplicates the draft.
    func commitDraft(replacingWith message: ChatMessage) async {
        if let idx = _committed.firstIndex(where: { $0.id == message.id }) {
            _committed[idx] = message
        } else {
            _committed.append(message)
        }
        draft = nil
        recompose()
    }

    func clearDraft() {
        draft = nil
        recompose()
    }

    func cancelLiveTool(_ toolCallId: String) {
        liveToolMessages.removeValue(forKey: toolCallId)
        liveToolStatus.removeValue(forKey: toolCallId)
        recompose()
    }

    // MARK: - Clear (new conversation)

    func clear() async {
        _committed.removeAll()
        envelope = ConversationEnvelope()
        draft = nil
        liveToolStatus = [:]
        liveToolMessages = [:]
        recompose()
    }

    // MARK: - Session management

    func switchConversation(to conversationId: String, projectRoot: URL?) {
        envelope = ConversationEnvelope(id: UUID(uuidString: conversationId) ?? UUID())
    }

    func restoreCommitted(_ messages: [ChatMessage]) {
        _committed = messages.filter { !$0.isDraft }
        recompose()
    }

    // MARK: - Subject

    func updateSubject(_ subject: String) {
        envelope.subject = subject
    }

    // MARK: - Draft / live tool messages (ephemeral UI state only)

    func setDraft(_ message: ChatMessage) {
        draft = message
        recompose()
    }

    func getDraftMessage(id: UUID) -> ChatMessage? {
        draft?.id == id ? draft : nil
    }

    func setLiveToolMessage(_ message: ChatMessage) {
        guard let id = message.toolCallId else { return }
        liveToolMessages[id] = message
        liveToolStatus[id] = message.toolStatus
        recompose()
    }

    func clearLiveToolMessage(_ toolCallId: String) {
        liveToolMessages.removeValue(forKey: toolCallId)
        liveToolStatus.removeValue(forKey: toolCallId)
        recompose()
    }

    // MARK: - Display composition

    private func recompose() {
        var display = _committed

        // Overlay live tool messages in stable order
        let sortedLive = liveToolMessages.values.sorted { $0.timestamp < $1.timestamp }
        for msg in sortedLive {
            if let idx = display.firstIndex(where: { $0.toolCallId == msg.toolCallId && $0.toolCallId != nil }) {
                display[idx] = msg
            } else {
                display.append(msg)
            }
        }

        // Append draft
        if let draft {
            if let idx = display.firstIndex(where: { $0.id == draft.id }) {
                display[idx] = draft
            } else {
                display.append(draft)
            }
        }

        messages = display
    }
}

// MARK: - Bridging (legacy methods — wrappers only)

extension ChatHistoryCoordinator {
    var committedMessages: [ChatMessage] { _committed }
    var requestMessages: [ChatMessage] { _committed }

    /// Clear the conversation and reset state.
    func clearConversation() {
        _committed.removeAll()
        draft = nil
        liveToolStatus = [:]
        liveToolMessages = [:]
        recompose()
    }

    /// Append multiple messages atomically (for session restore).
    func append(contentsOf messages: [ChatMessage]) async {
        _committed.append(contentsOf: messages)
        envelope.updatedAt = Date()
        recompose()
    }

    /// Insert is NOT append-only — kept for recovery-context injection only.
    /// Use sparse: only for system recovery messages at index 0.
    func insert(_ message: ChatMessage, at index: Int) {
        let safeIndex = min(max(0, index), _committed.endIndex)
        _committed.insert(message, at: safeIndex)
        envelope.updatedAt = Date()
        recompose()
    }
}

// MARK: - ConversationHistoryProviding

extension ChatHistoryCoordinator: ConversationHistoryProviding {}
