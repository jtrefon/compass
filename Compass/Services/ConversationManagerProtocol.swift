import Foundation

public struct ConversationTabItem: Identifiable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// A lightweight record of a conversation that was closed (but not discarded),
/// surfaced in the recovery dropdown so the user can reopen it.
public struct ClosedConversation: Identifiable, Equatable, Codable {
    public let id: String
    public let title: String
    public let closedAt: Date
    public let messageCount: Int
    public let byteSize: Int

    public init(id: String, title: String, closedAt: Date, messageCount: Int, byteSize: Int = 0) {
        self.id = id
        self.title = title
        self.closedAt = closedAt
        self.messageCount = messageCount
        self.byteSize = byteSize
    }

    /// Tolerant decoding: legacy persisted records lack `byteSize`; default it
    /// to 0 instead of failing the decode during registry migration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        closedAt = try c.decode(Date.self, forKey: .closedAt)
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        byteSize = try c.decodeIfPresent(Int.self, forKey: .byteSize) ?? 0
    }
}

public struct ConversationProviderIssueState: Equatable {
    public let providerName: String
    public let issueType: String
    public let statusCode: Int?
    public let message: String
    public let cooldownUntil: Date?

    public init(
        providerName: String,
        issueType: String,
        statusCode: Int?,
        message: String,
        cooldownUntil: Date?
    ) {
        self.providerName = providerName
        self.issueType = issueType
        self.statusCode = statusCode
        self.message = message
        self.cooldownUntil = cooldownUntil
    }
}

@MainActor
public protocol ConversationManagerProtocol: AnyObject, StatePublisherProtocol {
    var messages: [ChatMessage] { get }
    var conversationTabs: [ConversationTabItem] { get }
    var closedConversations: [ClosedConversation] { get }
    var currentInput: String { get set }
    var isSending: Bool { get }
    var error: String? { get }
    var currentMode: AIMode { get set }
    var currentConversationId: String { get }
    var providerIssue: ConversationProviderIssueState? { get }

    func sendMessage()
    func sendMessage(context: String?)
    func clearConversation()
    func startNewConversation()
    func switchConversation(to id: String)
    func closeConversation(id: String)
    func recoverConversation(id: String)
    func discardClosedConversation(id: String)
    func stopGeneration()
    func updateProjectRoot(_ root: URL)
    func updateCodebaseIndex(_ index: CodebaseIndexProtocol?)
    func updateAIService(_ service: AIService)
}
