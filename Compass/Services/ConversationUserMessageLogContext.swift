public struct ConversationUserMessageLogContext {
    public struct Identity {
        public let conversationId: String
        public let projectRootPath: String

        public init(conversationId: String, projectRootPath: String) {
            self.conversationId = conversationId
            self.projectRootPath = projectRootPath
        }
    }

    public struct MessageDetails {
        public let text: String
        public let mode: String
        public let hasSelectionContext: Bool

        public init(text: String, mode: String, hasSelectionContext: Bool) {
            self.text = text
            self.mode = mode
            self.hasSelectionContext = hasSelectionContext
        }
    }

    public let identity: Identity
    public let details: MessageDetails

    public init(identity: Identity, details: MessageDetails) {
        self.identity = identity
        self.details = details
    }
}
