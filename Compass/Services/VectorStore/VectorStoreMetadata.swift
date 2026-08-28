import Foundation

/// Points to the original log entry that produced this vector.
/// Used instead of inline `text` to avoid duplicating content from `.ide/logs/`.
public struct SourceReference: Codable, Sendable {
    public let conversationId: String
    /// 0-based index of the message in the conversation NDJSON.
    public let messageIndex: Int

    public init(conversationId: String, messageIndex: Int) {
        self.conversationId = conversationId
        self.messageIndex = messageIndex
    }
}

public struct VectorStoreMetadata: Codable, Sendable {
    public struct Entry: Codable, Sendable, Identifiable {
        public let id: String
        /// Inline text for entries that don't have a source log (e.g. tool results).
        /// Nil when `sourceReference` is set (text lives in the conversation log).
        public let text: String?
        public let source: String
        public let timestamp: Date
        public let category: String?
        public let embeddingModel: String
        /// Non-nil when this entry references text in a conversation log file.
        public let sourceReference: SourceReference?

        public init(
            id: String,
            text: String?,
            source: String,
            timestamp: Date = Date(),
            category: String? = nil,
            embeddingModel: String,
            sourceReference: SourceReference? = nil
        ) {
            self.id = id
            self.text = text
            self.source = source
            self.timestamp = timestamp
            self.category = category
            self.embeddingModel = embeddingModel
            self.sourceReference = sourceReference
        }
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL
    /// URL to the `.ide/logs/` directory for resolving source references.
    private let logsBaseURL: URL?

    public init(fileURL: URL, logsBaseURL: URL? = nil) {
        self.fileURL = fileURL
        self.logsBaseURL = logsBaseURL
    }

    public func entry(for id: String) -> Entry? {
        entries[id]
    }

    public mutating func add(_ entry: Entry) {
        entries[entry.id] = entry
    }

    public mutating func remove(id: String) {
        entries.removeValue(forKey: id)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public var all: [Entry] {
        Array(entries.values)
    }

    public var count: Int {
        entries.count
    }

    /// Resolves the full text for an entry, fetching from the conversation log
    /// when `sourceReference` is set instead of inline `text`.
    public func resolvedText(for entry: Entry) -> String? {
        if let text = entry.text { return text }
        guard let ref = entry.sourceReference,
              let logsBaseURL else { return nil }
        let convDir = logsBaseURL
            .appendingPathComponent("conversations")
            .appendingPathComponent(ref.conversationId)
        let fileURL = convDir.appendingPathComponent("conversation.ndjson")
        guard let data = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let lines = data.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard ref.messageIndex >= 0, ref.messageIndex < lines.count else { return nil }
        let line = lines[ref.messageIndex]
        guard let event = try? JSONDecoder().decode(ConversationLogEvent.self, from: Data(line.utf8)),
              case .string(let content) = event.data?["content"] else { return nil }
        return content
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    public mutating func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = [:]
            return
        }
        let data = try Data(contentsOf: fileURL)
        entries = try JSONDecoder().decode([String: Entry].self, from: data)
    }
}
