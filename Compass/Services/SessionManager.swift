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

        /// Reads a snapshot from disk without going through the in-memory cache.
        static func loadFromDisk(sessionId: String, projectRoot: URL) -> SessionSnapshot? {
            let url = SessionManifestStore.snapshotURL(sessionId: sessionId, projectRoot: projectRoot)
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else {
                return nil
            }
            return snapshot
        }

        /// Writes a snapshot to disk (atomic replace).
        static func saveToDisk(sessionId: String, snapshot: SessionSnapshot, projectRoot: URL) {
            let dir = SessionManifestStore.sessionsDirectory(projectRoot: projectRoot)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = SessionManifestStore.snapshotURL(sessionId: sessionId, projectRoot: projectRoot)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    @Published private(set) var conversationTabs: [ConversationTabItem] = []
    @Published private(set) var closedConversations: [ClosedConversation] = []

    private let historyCoordinator: ChatHistoryCoordinator
    private var projectRoot: URL
    private var currentSessionId: String

    /// Single source of truth for the session registry (order/selection/archive).
    /// Persisted as `.ide/chat/sessions/manifest.json` — one file per project.
    private var manifest: SessionManifest

    /// Lazy snapshot cache. Boot only reads the manifest (fast); snapshots are
    /// decoded from disk on demand when a session is restored.
    private var conversationSessionSnapshots: [String: SessionSnapshot]

    private let manifestStore = SessionManifestStore()

    /// When the registry heals itself from disk (broken order), cap the number
    /// of tabs restored so the tab bar isn't flooded with hundreds of entries.
    private static let maxTabsOnHeal = 20

    /// Legacy pre-manifest registry (UserDefaults). Read once for migration,
    /// then never used again.
    private static let orderDefaultsKey = "SessionManager.sessionOrder"
    private static let selectedIdDefaultsKey = "SessionManager.selectedId"
    private static let closedRegistryKey = "SessionManager.closedRegistry"

    private static var sessionDefaults: UserDefaults {
        AppRuntimeEnvironment.userDefaults
    }

    init(
        historyCoordinator: ChatHistoryCoordinator,
        projectRoot: URL
    ) {
        self.historyCoordinator = historyCoordinator
        self.projectRoot = projectRoot
        self.manifest = SessionManifest()
        self.conversationSessionSnapshots = [:]
        self.currentSessionId = ""

        hydrate(projectRoot: projectRoot)
    }

    var selectedId: String {
        currentSessionId
    }

    // MARK: - Hydration (boot / project switch)

    /// Loads the registry from the project manifest (fast path), migrates the
    /// legacy UserDefaults registry (one-time), or heals from the on-disk
    /// snapshot store. Then reconciles the registry with what actually exists
    /// on disk so no reachable session is ever forgotten.
    private func hydrate(projectRoot: URL) {
        manifest = loadOrHealManifest(projectRoot: projectRoot)
        reconcileRegistryWithDisk()
        resolveInitialSelection()
        manifestStore.save(manifest, projectRoot: projectRoot)
        refreshTabs()
        refreshClosed()
    }

    private func loadOrHealManifest(projectRoot: URL) -> SessionManifest {
        if let stored = manifestStore.load(projectRoot: projectRoot) {
            return stored
        }
        if let legacy = loadLegacyRegistry(projectRoot: projectRoot) {
            return legacy
        }
        // Fresh project or broken registry: rebuild entirely from disk. Nothing
        // on disk is ever forgotten just because the manifest is missing.
        return manifestStore.rebuildFromDisk(projectRoot: projectRoot)
    }

    private func loadLegacyRegistry(projectRoot: URL) -> SessionManifest? {
        let defaults = Self.sessionDefaults
        guard let orderData = defaults.data(forKey: Self.orderDefaultsKey),
              let order = try? JSONDecoder().decode([String].self, from: orderData),
              !order.isEmpty else {
            return nil
        }
        let selectedId = defaults.string(forKey: Self.selectedIdDefaultsKey)
        var closedIds: [String] = []
        if let closedData = defaults.data(forKey: Self.closedRegistryKey),
           let registry = try? JSONDecoder().decode([String: ClosedConversation].self, from: closedData) {
            closedIds = registry.keys.sorted {
                (registry[$0]?.closedAt ?? .distantPast) > (registry[$1]?.closedAt ?? .distantPast)
            }
        }
        var migrated = manifestStore.rebuildFromDisk(projectRoot: projectRoot)
        migrated.order = order.filter { migrated.sessions[$0] != nil }
        migrated.archivedIds = closedIds.filter { migrated.sessions[$0] != nil }
        migrated.selectedId = selectedId
        return migrated
    }

    /// Drops registry entries whose snapshot file no longer exists and
    /// reattaches every on-disk snapshot that the registry forgot — those
    /// become archived (reachable from the clock dropdown).
    private func reconcileRegistryWithDisk() {
        let diskIds = Set(manifest.sessions.keys)
        let orderIds = Set(manifest.order)
        manifest.order = manifest.order.filter { diskIds.contains($0) }
        manifest.selectedId = manifest.selectedId.flatMap { diskIds.contains($0) ? $0 : nil }

        let archivedIds = Set(manifest.archivedIds)
            .subtracting(orderIds)
            .union(diskIds.subtracting(orderIds))
        manifest.archivedIds = archivedIds.sorted {
            (manifest.sessions[$0]?.updatedAt ?? .distantPast) > (manifest.sessions[$1]?.updatedAt ?? .distantPast)
        }

        // Heal cap: a broken/empty tab order must not flood the tab bar —
        // promote the most recent archived sessions to tabs, keep the rest archived.
        if manifest.order.isEmpty, !manifest.sessions.isEmpty {
            let candidates = manifest.archivedIds.sorted {
                (manifest.sessions[$0]?.updatedAt ?? .distantPast) > (manifest.sessions[$1]?.updatedAt ?? .distantPast)
            }
            manifest.order = Array(candidates.prefix(Self.maxTabsOnHeal))
            manifest.archivedIds = Array(candidates.dropFirst(Self.maxTabsOnHeal))
        }
    }

    /// Selects the active session: the manifest's selection if still valid,
    /// otherwise the most recent session (recovered to a tab if it was
    /// archived), otherwise a fresh blank session.
    private func resolveInitialSelection() {
        let allIds = Set(manifest.order).union(manifest.archivedIds)
        if let selected = manifest.selectedId, allIds.contains(selected) {
            currentSessionId = selected
        } else {
            let sorted = allIds.sorted {
                (manifest.sessions[$0]?.updatedAt ?? .distantPast) > (manifest.sessions[$1]?.updatedAt ?? .distantPast)
            }
            if let mostRecent = sorted.first {
                currentSessionId = mostRecent
                if !manifest.order.contains(mostRecent) {
                    manifest.order.insert(mostRecent, at: 0)
                    manifest.archivedIds.removeAll { $0 == mostRecent }
                }
            } else {
                let freshId = UUID().uuidString
                let now = Date()
                currentSessionId = freshId
                manifest.order = [freshId]
                manifest.sessions[freshId] = SessionManifest.Entry(
                    subject: "",
                    mode: .chat,
                    createdAt: now,
                    updatedAt: now,
                    closedAt: nil,
                    messageCount: 0,
                    byteSize: 0
                )
                // Persist the blank snapshot so the registry and the on-disk
                // store agree from the very first boot (the validation in
                // reconcileRegistryWithDisk requires a snapshot file).
                let blank = SessionSnapshot(
                    messages: [],
                    mode: .chat,
                    input: "",
                    subject: "",
                    createdAt: now,
                    updatedAt: now,
                    closedAt: nil
                )
                SessionSnapshot.saveToDisk(sessionId: freshId, snapshot: blank, projectRoot: projectRoot)
            }
        }
        manifest.selectedId = currentSessionId
    }

    // MARK: - Tab Management

    private func refreshTabs() {
        conversationTabs = manifest.order.enumerated().map { index, id in
            let subject = manifest.sessions[id]?.subject ?? ""
            let title = subject.isEmpty ? "Chat \(index + 1)" : subject
            return ConversationTabItem(id: id, title: title)
        }
    }

    private func refreshClosed() {
        closedConversations = manifest.archivedIds
            .compactMap { id in
                guard let entry = manifest.sessions[id] else { return nil }
                return ClosedConversation(
                    id: id,
                    title: entry.subject.isEmpty ? "Chat" : entry.subject,
                    closedAt: entry.closedAt ?? entry.updatedAt,
                    messageCount: entry.messageCount,
                    byteSize: entry.byteSize
                )
            }
            .sorted { $0.closedAt > $1.closedAt }
    }

    // MARK: - Snapshot Management

    func saveSnapshot(input: String, mode: AIMode) {
        let sessionId = currentSessionId
        let messages = historyCoordinator.committedMessages
        let subject = historyCoordinator.conversationEnvelope.subject
        let previous = conversationSessionSnapshots[sessionId]

        // Empty-overwrite guard: an empty in-memory history must never clobber
        // a non-empty snapshot on disk (boot-order regression — this used to
        // wipe the last active session on every launch).
        if messages.isEmpty,
           let disk = SessionSnapshot.loadFromDisk(sessionId: sessionId, projectRoot: projectRoot),
           !disk.messages.isEmpty {
            return
        }

        // No-op guard: don't rewrite disk/manifest when nothing changed.
        if let previous,
           previous.messages.count == messages.count,
           previous.subject == subject,
           previous.mode == mode,
           previous.input == input {
            return
        }

        let snapshot = SessionSnapshot(
            messages: messages,
            mode: mode,
            input: input,
            subject: subject,
            createdAt: previous?.createdAt ?? Date(),
            updatedAt: Date(),
            closedAt: previous?.closedAt
        )
        conversationSessionSnapshots[sessionId] = snapshot
        SessionSnapshot.saveToDisk(sessionId: sessionId, snapshot: snapshot, projectRoot: projectRoot)
        updateManifestEntry(for: sessionId, snapshot: snapshot)
        persistSelectionAndOrder()
    }

    func restoreSession(_ sessionId: String, input: inout String, mode: inout AIMode) {
        let snapshot = loadSnapshotForRestore(sessionId)
        currentSessionId = sessionId
        historyCoordinator.switchConversation(to: sessionId)
        historyCoordinator.restoreCommitted(snapshot.messages)
        historyCoordinator.updateSubject(snapshot.subject)

        mode = snapshot.mode
        input = snapshot.input
    }

    /// Lazy snapshot loading: decodes from disk only when the session is
    /// actually restored, never at boot.
    private func loadSnapshotForRestore(_ sessionId: String) -> SessionSnapshot {
        if let cached = conversationSessionSnapshots[sessionId] {
            return cached
        }
        if let disk = SessionSnapshot.loadFromDisk(sessionId: sessionId, projectRoot: projectRoot) {
            conversationSessionSnapshots[sessionId] = disk
            return disk
        }
        let now = Date()
        let fresh = SessionSnapshot(
            messages: [],
            mode: .chat,
            input: "",
            subject: "",
            createdAt: now,
            updatedAt: now,
            closedAt: nil
        )
        conversationSessionSnapshots[sessionId] = fresh
        return fresh
    }

    // MARK: - Session Lifecycle

    func startNew(input: inout String, mode: inout AIMode) -> String {
        let newConversationId = UUID().uuidString
        manifest.order.append(newConversationId)
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
        SessionSnapshot.saveToDisk(sessionId: newConversationId, snapshot: snapshot, projectRoot: projectRoot)
        updateManifestEntry(for: newConversationId, snapshot: snapshot)
        restoreSession(newConversationId, input: &input, mode: &mode)
        refreshTabs()
        persistSelectionAndOrder()
        AIToolTraceLogger.shared.startNewSession(conversationId: newConversationId)
        return newConversationId
    }

    func switchTo(id: String, input: inout String, mode: inout AIMode) -> Bool {
        guard id != currentSessionId, manifest.order.contains(id) else { return false }
        restoreSession(id, input: &input, mode: &mode)
        refreshTabs()
        persistSelectionAndOrder()
        return true
    }

    func close(id: String, input: inout String, mode: inout AIMode) -> Bool {
        guard manifest.order.count > 1 else { return false }
        guard let closingIndex = manifest.order.firstIndex(of: id) else { return false }

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
            SessionSnapshot.saveToDisk(sessionId: id, snapshot: archived, projectRoot: projectRoot)
            closedSnapshot = archived
        } else if let snapshot = SessionSnapshot.loadFromDisk(sessionId: id, projectRoot: projectRoot) {
            closedSnapshot = snapshot
        } else {
            return false
        }

        manifest.order.remove(at: closingIndex)
        if !manifest.archivedIds.contains(id) {
            manifest.archivedIds.append(id)
        }
        updateManifestEntry(for: id, snapshot: closedSnapshot)
        refreshClosed()

        if id == currentSessionId {
            let fallbackIndex = min(closingIndex, manifest.order.count - 1)
            let fallbackId = manifest.order[fallbackIndex]
            restoreSession(fallbackId, input: &input, mode: &mode)
        }

        refreshTabs()
        persistSelectionAndOrder()
        return true
    }

    /// Reopens a previously closed conversation, restoring it as a live tab.
    @discardableResult
    func recover(id: String, input: inout String, mode: inout AIMode) -> Bool {
        guard let snapshot = conversationSessionSnapshots[id]
                ?? SessionSnapshot.loadFromDisk(sessionId: id, projectRoot: projectRoot) else {
            return false
        }

        // If the session is already open (e.g. recovered to a still-live id), just switch.
        if !manifest.order.contains(id) {
            manifest.order.append(id)
        }
        manifest.archivedIds.removeAll { $0 == id }
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
        SessionSnapshot.saveToDisk(sessionId: id, snapshot: reopened, projectRoot: projectRoot)
        updateManifestEntry(for: id, snapshot: reopened)
        refreshClosed()

        restoreSession(id, input: &input, mode: &mode)
        refreshTabs()
        persistSelectionAndOrder()
        return true
    }

    /// Permanently discards a closed conversation so it no longer appears in the recovery dropdown.
    func discardClosed(id: String) {
        guard manifest.archivedIds.contains(id) else { return }
        manifest.archivedIds.removeAll { $0 == id }
        manifest.sessions.removeValue(forKey: id)
        conversationSessionSnapshots[id] = nil
        manifestStore.deleteSnapshot(sessionId: id, projectRoot: projectRoot)
        manifestStore.save(manifest, projectRoot: projectRoot)
        refreshClosed()
    }

    func updateProjectRoot(_ newRoot: URL, input: inout String, mode: inout AIMode) {
        // Persist the outgoing project's current session first (guarded against
        // empty-overwrite). This runs against the OLD root — the boot-order
        // regression used to snapshot empty history over the real project.
        saveSnapshot(input: input, mode: mode)

        projectRoot = newRoot
        conversationSessionSnapshots = [:]
        hydrate(projectRoot: newRoot)
        restoreSession(currentSessionId, input: &input, mode: &mode)
    }

    // MARK: - Manifest persistence

    private func updateManifestEntry(for sessionId: String, snapshot: SessionSnapshot) {
        let url = SessionManifestStore.snapshotURL(sessionId: sessionId, projectRoot: projectRoot)
        manifest.sessions[sessionId] = SessionManifest.Entry(
            subject: snapshot.subject,
            mode: snapshot.mode,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            closedAt: snapshot.closedAt,
            messageCount: snapshot.messages.count,
            byteSize: SessionManifestStore.fileSize(of: url)
        )
    }

    private func persistSelectionAndOrder() {
        manifest.selectedId = currentSessionId
        manifestStore.save(manifest, projectRoot: projectRoot)
    }
}
