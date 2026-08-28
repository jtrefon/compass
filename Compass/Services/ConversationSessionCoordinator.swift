import Combine
import Foundation

/// Owns session/tab/history observation glue that previously lived in
/// `ConversationManager` (832 lines). The manager now holds a single
/// `sessionCoordinator` and forwards `startNew`/`switch`/`close` calls.
///
/// **Design rationale:**
/// - `SessionManager` already owns the session order/snapshots/disk; this
///   coordinator is the *observation + snapshot* glue (4 subscriptions + 2
///   helpers) so `ConversationManager` stays a thin `@Published` facade.
/// - `@MainActor` because `SessionManager` and `ChatHistoryCoordinator` are
///   main-actor confined and every `sink` delivers on main.
@MainActor
final class ConversationSessionCoordinator: ObservableObject {

    // MARK: - Published state mirrored from SessionManager / ChatHistoryCoordinator

    @Published private(set) var conversationTabs: [ConversationTabItem] = []
    @Published private(set) var closedConversations: [ClosedConversation] = []
    @Published private(set) var messages: [ChatMessage] = []

    // MARK: - Dependencies

    private let sessionManager: SessionManager
    private let historyCoordinator: ChatHistoryCoordinator
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(sessionManager: SessionManager, historyCoordinator: ChatHistoryCoordinator) {
        self.sessionManager = sessionManager
        self.historyCoordinator = historyCoordinator
        observeSessionTabs()
        observeHistoryMessages()
    }

    // MARK: - Observation (moved from ConversationManager)

    private func observeSessionTabs() {
        sessionManager.$conversationTabs
            .sink { [weak self] tabs in self?.conversationTabs = tabs }
            .store(in: &cancellables)
        sessionManager.$closedConversations
            .sink { [weak self] closed in self?.closedConversations = closed }
            .store(in: &cancellables)
    }

    private func observeHistoryMessages() {
        historyCoordinator.$messages
            .sink { [weak self] msgs in self?.messages = msgs }
            .store(in: &cancellables)
    }

    // MARK: - Snapshot helpers (moved from ConversationManager)

    func saveCurrentSnapshot(input: String, mode: AIMode) {
        sessionManager.saveSnapshot(input: input, mode: mode)
    }

    func restoreSession(_ sessionId: String, input: inout String, mode: inout AIMode) {
        sessionManager.restoreSession(sessionId, input: &input, mode: &mode)
    }

    // MARK: - Session lifecycle — thin wrappers that keep SessionManager as source of truth

    func startNew(input: inout String, mode: inout AIMode) -> String {
        sessionManager.startNew(input: &input, mode: &mode)
    }

    func switchTo(id: String, input: inout String, mode: inout AIMode) -> Bool {
        sessionManager.switchTo(id: id, input: &input, mode: &mode)
    }

    func close(id: String, input: inout String, mode: inout AIMode) -> Bool {
        sessionManager.close(id: id, input: &input, mode: &mode)
    }

    func recover(id: String, input: inout String, mode: inout AIMode) -> Bool {
        sessionManager.recover(id: id, input: &input, mode: &mode)
    }

    func discardClosed(id: String) {
        sessionManager.discardClosed(id: id)
    }

    func clearHistory() {
        historyCoordinator.clearConversation()
    }

    func updateProjectRoot(_ newRoot: URL, input: inout String, mode: inout AIMode) {
        sessionManager.updateProjectRoot(newRoot, input: &input, mode: &mode)
    }
}
