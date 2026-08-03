import Foundation

public extension VectorStoreService {
    struct ConversationTurn: Sendable {
        public let query: String
        public let response: String
        public let source: String
        public let category: String?

        public init(
            query: String,
            response: String,
            source: String = "conversation",
            category: String? = "conversation"
        ) {
            self.query = query
            self.response = response
            self.source = source
            self.category = category
        }
    }

    struct ConversationHistoryResult: Sendable {
        public let query: String
        public let response: String
        public let score: Float
        public let timestamp: Date
    }

    func storeConversationTurn(
        turn: ConversationTurn,
        queryVector: [Float],
        responseVector: [Float]
    ) throws {
        let queryId = try addEntry(
            text: turn.query,
            vector: queryVector,
            source: turn.source,
            category: turn.category
        )

        let responseText = turn.response.prefix(500)
        try addEntry(
            text: String(responseText),
            vector: responseVector,
            source: turn.source,
            category: turn.category,
            id: "resp_\(queryId)"
        )
    }

    func retrieveRelevantHistory(
        queryVector: [Float],
        limit: Int = 5
    ) throws -> [ConversationHistoryResult] {
        let results = try search(queryVector: queryVector, limit: limit)
        return results.compactMap { result in
            guard let meta = result.metadata, let text = meta.text else { return nil }
            return ConversationHistoryResult(
                query: text,
                response: text,
                score: result.score,
                timestamp: meta.timestamp
            )
        }
    }
}
