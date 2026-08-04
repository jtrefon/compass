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
}
