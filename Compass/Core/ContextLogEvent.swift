import Foundation

/// Generic event for contextual data that should be logged and/or embedded.
/// The single ingestion point for any component that produces data
/// useful for future RAG retrieval.
public struct ContextLogEvent: Event, Sendable {
    public let conversationId: String?
    public let source: String
    public let content: String
    public let metadata: [String: String]

    public init(
        conversationId: String?,
        source: String,
        content: String,
        metadata: [String: String] = [:]
    ) {
        self.conversationId = conversationId
        self.source = source
        self.content = content
        self.metadata = metadata
    }
}
