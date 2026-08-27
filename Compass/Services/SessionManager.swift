import Foundation

@MainActor
final class SessionManager: ObservableObject {

    struct SessionSnapshot: Codable {
        let messages: [ChatMessage]
        let mode: AIMode
        let input: String
        let subject: String
        let createdAt: Date
        let updatedAt: Date
        let closedAt: Date?

        /// Tolerant decoding so sessions persisted by older builds (which lack the
        /// date fields) can still be recovered instead of failing to decode and
        /// silently dropping the conversation.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messages = try c.decode([ChatMessage].self, forKey: .messages)
            mode = try c.decode(AIMode.self, forKey: .mode)
            input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
            subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
            closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        }

        init(
            messages: [ChatMessage],
            mode: AIMode,
            input: String,
            subject: String,
            createdAt: Date,
            updatedAt: Date,
            closedAt: Date?
        ) {
            self.messages = messages
            self.mode = mode
            self.input = input
            self.subject = subject
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.closedAt = closedAt
        }
    }

    @Published private(set) var conversationTabs: [ConversationTabItem] = []
    @Published private(set) var closedConversations: [ClosedConversation] = []

    private let historyCoordinator: ChatHistoryCoordinator
    private var projectRoot: URL
    private var currentSessionId: String
    private var conversationSessionOrder: [String]
    private var conversationSessionSnapshots: [String: SessionSnapshot]
    private var closedRegistry: [String: ClosedConversation] = [:]

    private static let orderDefaultsKey = "SessionManager.sessionOrder"
    private static let selectedIdDefaultsKey = "SessionManager.selectedId"

    /// Session/selection state must respect the launch context's test profile:
    /// harness runs get their own defaults suite instead of leaking the user's
    /// selected conversation, closed registry, and session order (and vice
    /// versa). Settings (model, provider) intentionally stay shared.
    private static var sessionDefaults: UserDefaults {
        AppRuntimeEnvironment.userDefaults
    }
    private static let closedRegistryKey = "SessionManager.closedRegistry"

    init(
        historyCoordinator: ChatHistoryCoordinator,
        projectRoot: URL
    ) {
        self.historyCoordinator = historyCoordinator
        self.projectRoot = projectRoot
        let loadedOrder: [String]
        let loadedSelectedId: String
        if let savedOrder = Self.loadSessionOrder(),
           let savedSelectedId = Self.loadSelectedId(),
           !savedOrder.isEmpty {
            loadedOrder = savedOrder
            loadedSelectedId = savedSelectedId
        } else {
            loadedOrder = [historyCoordinator.currentConversationId]
            loadedSelectedId = historyCoordinator.currentConversationId
        }
        self.currentSessionId = loadedSelectedId
        self.conversationSessionOrder = loadedOrder
        self.conversationSessionSnapshots = [:]
        for sessionId in loadedOrder {
            if let snapshot = Self.loadSnapshot(sessionId: sessionId, projectRoot: projectRoot) {
                conversationSessionSnapshots[sessionId] = snapshot
            }
        }
        if conversationSessionSnapshots[currentSessionId] == nil {
            let now = Date()
            conversationSessionSnapshots[currentSessionId] = SessionSnapshot(
                messages: historyCoordinator.committedMessages,
                mode: .chat,
                input: "",
                subject: "",
                createdAt: now,
                updatedAt: now,
                closedAt: nil
            )
        }
        loadClosedRegistry()
        refreshTabs()
    }

    var selectedId: String {
        currentSessionId
    }

    // MARK: - Tab Management

    private func refreshTabs() {
        conversationTabs = conversationSessionOrder.enumerated().map { index, id in
            let snapshotSubject = conversationSessionSnapshots[id]?.subject ?? ""
            let title = snapshotSubject.isEmpty ? "Chat \(index + 1)" : snapshotSubject
            return ConversationTabItem(id: id, title: title)
        }
    }

    private func refreshClosed() {
        closedConversations = closedRegistry.values.sorted { $0.closedAt > $1.closedAt }
    }

    private func loadClosedRegistry() {
        guard let data = Self.sessionDefaults.data(forKey: Self.closedRegistryKey),
              let registry = try? JSONDecoder().decode([String: ClosedConversation].self, from: data) else {
            closedRegistry = [:]
            return
        }
        closedRegistry = registry
        refreshClosed()
    }

    private func saveClosedRegistry() {
        if let data = try? JSONEncoder().encode(closedRegistry) {
            Self.sessionDefaults.set(data, forKey: Self.closedRegistryKey)
        }
    }

    // MARK: - Snapshot Management

    func saveSnapshot(input: String, mode: AIMode) {
        let previous = conversationSessionSnapshots[currentSessionId]
        let snapshot = SessionSnapshot(
            messages: historyCoordinator.committedMessages,
            mode: mode,
            input: input,
            subject: historyCoordinator.conversationEnvelope.subject,
            createdAt: previous?.createdAt ?? Date(),
            updatedAt: Date(),
            closedAt: previous?.closedAt
        )
        conversationSessionSnapshots[currentSessionId] = snapshot
        Self.saveSnapshot(sessionId: currentSessionId, snapshot: snapshot, projectRoot: projectRoot)
        Self.saveSessionOrder(conversationSessionOrder)
        Self.saveSelectedId(currentSessionId)
    }

    func restoreSession(_ sessionId: String, input: inout String, mode: inout AIMode) {
        let snapshot = conversationSessionSnapshots[sessionId] ?? SessionSnapshot(
            messages: [],
            mode: .chat,
            input: "",
            subject: "",
            createdAt: Date(),
            updatedAt: Date(),
            closedAt: nil
        )
        currentSessionId = sessionId
        historyCoordinator.switchConversation(to: sessionId, projectRoot: projectRoot)
        historyCoordinator.restoreCommitted(snapshot.messages)
        historyCoordinator.updateSubject(snapshot.subject)

        mode = snapshot.mode
        input = snapshot.input
    }

    // MARK: - Session Lifecycle

    func startNew(input: inout String, mode: inout AIMode) -> String {
        let newConversationId = UUID().uuidString
        conversationSessionOrder.append(newConversationId)
        let now = Date()
        let snapshot = SessionSnapshot(
            messages: [],
            mode: mode,
            input: "",
            subject: "",
            createdAt: now,
            updatedAt: now,
            closedAt: nil
        )
        conversationSessionSnapshots[newConversationId] = snapshot
        Self.saveSnapshot(sessionId: newConversationId, snapshot: snapshot, projectRoot: projectRoot)
        restoreSession(newConversationId, input: &input, mode: &mode)
        refreshTabs()
        Self.saveSessionOrder(conversationSessionOrder)
        Self.saveSelectedId(currentSessionId)
        return newConversationId
    }

    func switchTo(id: String, input: inout String, mode: inout AIMode) -> Bool {
        guard id != currentSessionId, conversationSessionSnapshots[id] != nil else { return false }
        restoreSession(id, input: &input, mode: &mode)
        refreshTabs()
        Self.saveSelectedId(currentSessionId)
        return true
    }

    func close(id: String, input: inout String, mode: inout AIMode) -> Bool {
        guard conversationSessionOrder.count > 1 else { return false }
        guard let closingIndex = conversationSessionOrder.firstIndex(of: id) else { return false }

        // Move the session into the recoverable "closed" registry instead of
        // deleting it outright, so the user can reopen it later from the dropdown.
        let closedSnapshot: SessionSnapshot
        if let snapshot = conversationSessionSnapshots[id] {
            let archived = SessionSnapshot(
                messages: snapshot.messages,
                mode: snapshot.mode,
                input: snapshot.input,
                subject: snapshot.subject,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                closedAt: Date()
            )
            conversationSessionSnapshots[id] = archived
            Self.saveSnapshot(sessionId: id, snapshot: archived, projectRoot: projectRoot)
            closedSnapshot = archived
        } else if let snapshot = Self.loadSnapshot(sessionId: id, projectRoot: projectRoot) {
            closedSnapshot = snapshot
        } else {
            return false
        }

        conversationSessionOrder.remove(at: closingIndex)

        let closedTitle = (closedSnapshot.subject.isEmpty
            ? "Chat \(conversationSessionOrder.count + closedRegistry.count + 1)"
            : closedSnapshot.subject)
        closedRegistry[id] = ClosedConversation(
            id: id,
            title: closedTitle,
            closedAt: closedSnapshot.closedAt ?? Date(),
            messageCount: closedSnapshot.messages.count
        )
        saveClosedRegistry()
        refreshClosed()

        if id == currentSessionId {
            let fallbackIndex = min(closingIndex, conversationSessionOrder.count - 1)
            let fallbackId = conversationSessionOrder[fallbackIndex]
            restoreSession(fallbackId, input: &input, mode: &mode)
        }

        refreshTabs()
        Self.saveSessionOrder(conversationSessionOrder)
        Self.saveSelectedId(currentSessionId)
        return true
    }

    /// Reopens a previously closed conversation, restoring it as a live tab.
    @discardableResult
    func recover(id: String, input: inout String, mode: inout AIMode) -> Bool {
        guard let snapshot = conversationSessionSnapshots[id]
                ?? Self.loadSnapshot(sessionId: id, projectRoot: projectRoot) else {
            return false
        }

        // If the session is already open (e.g. recovered to a still-live id), just switch.
        if !conversationSessionOrder.contains(id) {
            conversationSessionOrder.append(id)
        }
        let reopened = SessionSnapshot(
            messages: snapshot.messages,
            mode: snapshot.mode,
            input: snapshot.input,
            subject: snapshot.subject,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            closedAt: nil
        )
        conversationSessionSnapshots[id] = reopened
        Self.saveSnapshot(sessionId: id, snapshot: reopened, projectRoot: projectRoot)

        closedRegistry.removeValue(forKey: id)
        saveClosedRegistry()
        refreshClosed()

        restoreSession(id, input: &input, mode: &mode)
        refreshTabs()
        Self.saveSessionOrder(conversationSessionOrder)
        Self.saveSelectedId(currentSessionId)
        return true
    }

    /// Permanently discards a closed conversation so it no longer appears in the recovery dropdown.
    func discardClosed(id: String) {
        closedRegistry.removeValue(forKey: id)
        conversationSessionSnapshots[id] = nil
        Self.deleteSnapshot(sessionId: id, projectRoot: projectRoot)
        saveClosedRegistry()
        refreshClosed()
    }

    func updateProjectRoot(_ newRoot: URL, input: inout String, mode: inout AIMode) {
        projectRoot = newRoot

        // Preserve existing order/snapshots — don't reset to a single entry.
        // The old code did `conversationSessionOrder = [migratedSessionId]` which
        // wiped 142 sessions down to 1 on every restart, emptying the "all
        // sessions" button. Now we keep the loaded order and just ensure the
        // current session is present.
        let migratedSessionId = historyCoordinator.currentConversationId
        if !conversationSessionOrder.contains(migratedSessionId) {
            conversationSessionOrder.append(migratedSessionId)
        }
        currentSessionId = migratedSessionId

        // Self-heal: if in-memory history is empty but disk has non-empty, keep disk.
        if historyCoordinator.committedMessages.isEmpty,
           let existing = Self.loadSnapshot(sessionId: migratedSessionId, projectRoot: projectRoot),
           !existing.messages.isEmpty {
            conversationSessionSnapshots[migratedSessionId] = existing
            refreshTabs()
            Self.saveSessionOrder(conversationSessionOrder)
            Self.saveSelectedId(currentSessionId)
            return
        }

        // Only snapshot if we have something to save — don't overwrite a
        // non-empty disk file with an empty in-memory history.
        if !historyCoordinator.committedMessages.isEmpty || conversationSessionSnapshots[migratedSessionId] == nil {
            let snapshot = SessionSnapshot(
                messages: historyCoordinator.committedMessages,
                mode: mode,
                input: input,
                subject: historyCoordinator.conversationEnvelope.subject,
                createdAt: conversationSessionSnapshots[migratedSessionId]?.createdAt ?? Date(),
                updatedAt: Date(),
                closedAt: nil
            )
            conversationSessionSnapshots[migratedSessionId] = snapshot
            Self.saveSnapshot(sessionId: migratedSessionId, snapshot: snapshot, projectRoot: projectRoot)
        }
        refreshTabs()
        Self.saveSessionOrder(conversationSessionOrder)
        Self.saveSelectedId(currentSessionId)
    }

    // MARK: - Disk Persistence

    private static func sessionsDirectory(projectRoot: URL) -> URL {
        projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func snapshotURL(sessionId: String, projectRoot: URL) -> URL {
        sessionsDirectory(projectRoot: projectRoot)
            .appendingPathComponent("\(sessionId).json")
    }

    private static func saveSnapshot(sessionId: String, snapshot: SessionSnapshot, projectRoot: URL) {
        let dir = sessionsDirectory(projectRoot: projectRoot)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = snapshotURL(sessionId: sessionId, projectRoot: projectRoot)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func loadSnapshot(sessionId: String, projectRoot: URL) -> SessionSnapshot? {
        let url = snapshotURL(sessionId: sessionId, projectRoot: projectRoot)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    private static func deleteSnapshot(sessionId: String, projectRoot: URL) {
        let url = snapshotURL(sessionId: sessionId, projectRoot: projectRoot)
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadSessionOrder() -> [String]? {
        guard let data = sessionDefaults.data(forKey: orderDefaultsKey),
              let order = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return order
    }

    private static func saveSessionOrder(_ order: [String]) {
        if let data = try? JSONEncoder().encode(order) {
            sessionDefaults.set(data, forKey: orderDefaultsKey)
        }
    }

    private static func loadSelectedId() -> String? {
        sessionDefaults.string(forKey: selectedIdDefaultsKey)
    }

    private static func saveSelectedId(_ id: String) {
        sessionDefaults.set(id, forKey: selectedIdDefaultsKey)
    }
}
