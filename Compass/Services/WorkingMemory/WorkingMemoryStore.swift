import Foundation

/// Conversation-scoped persistent working memory.
/// Actor for thread safety (matches VectorStoreService, ConversationPlanStore patterns).
/// Notes persist to `.ide/working-memory/{conversationId}.json` and survive
/// app restarts and context resets.
actor WorkingMemoryStore {
    static let shared = WorkingMemoryStore()

    private var snapshots: [String: WorkingMemorySnapshot] = [:]
    private var projectRoot: URL?
    private let maxNotesPerConversation = 50

    func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }

    func get(conversationId: String) -> WorkingMemorySnapshot {
        if let cached = snapshots[conversationId] {
            return cached
        }
        guard let url = fileURL(conversationId: conversationId),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WorkingMemorySnapshot.self, from: data) else {
            return WorkingMemorySnapshot()
        }
        snapshots[conversationId] = snapshot
        return snapshot
    }

    func add(conversationId: String, note: WorkingMemoryNote) {
        var snapshot = get(conversationId: conversationId)
        snapshot.notes.append(note)
        enforceMaxNotes(&snapshot)
        snapshots[conversationId] = snapshot
        persist(conversationId: conversationId, snapshot: snapshot)
    }

    func updateSection(conversationId: String, section: String, content: String, intent: NoteIntent) {
        var snapshot = get(conversationId: conversationId)
        snapshot.notes.removeAll { $0.section == section }
        snapshot.notes.append(WorkingMemoryNote(
            section: section,
            content: content,
            intent: intent
        ))
        enforceMaxNotes(&snapshot)
        snapshots[conversationId] = snapshot
        persist(conversationId: conversationId, snapshot: snapshot)
    }

    func clearSection(conversationId: String, section: String) {
        var snapshot = get(conversationId: conversationId)
        snapshot.notes.removeAll { $0.section == section }
        snapshots[conversationId] = snapshot
        persist(conversationId: conversationId, snapshot: snapshot)
    }

    func clear(conversationId: String) {
        snapshots.removeValue(forKey: conversationId)
        if let url = fileURL(conversationId: conversationId) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func markReset(conversationId: String) {
        var snapshot = get(conversationId: conversationId)
        snapshot.lastResetAt = Date()
        snapshots[conversationId] = snapshot
        persist(conversationId: conversationId, snapshot: snapshot)
    }

    func noteCount(conversationId: String) -> Int {
        get(conversationId: conversationId).notes.count
    }

    func allNoteTexts(conversationId: String) -> [String] {
        get(conversationId: conversationId).notes.map(\.content)
    }

    func editTargetSections(conversationId: String) -> Set<String> {
        get(conversationId: conversationId).editTargetSections()
    }

    // MARK: - Private

    private func enforceMaxNotes(_ snapshot: inout WorkingMemorySnapshot) {
        guard snapshot.notes.count > maxNotesPerConversation else { return }
        // Evict oldest finding notes first; keep edit_target notes
        let findingNotes = snapshot.notes
            .filter { $0.intent == .finding }
            .sorted { $0.timestamp < $1.timestamp }
        let toEvict = max(0, snapshot.notes.count - maxNotesPerConversation)
        let evictIds = Set(findingNotes.prefix(toEvict).map(\.id))
        snapshot.notes.removeAll { evictIds.contains($0.id) }
    }

    private func fileURL(conversationId: String) -> URL? {
        guard let projectRoot else { return nil }
        return projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("working-memory", isDirectory: true)
            .appendingPathComponent("\(conversationId).json")
    }

    private func persist(conversationId: String, snapshot: WorkingMemorySnapshot) {
        guard let url = fileURL(conversationId: conversationId) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}
