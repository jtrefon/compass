//
//  ChatMessage.swift
//  Compass
//
//  Created by AI Assistant on 25/08/2025.
//

import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

public enum ToolExecutionStatus: String, Codable, Sendable {
    case executing
    case completed
    case failed
}

public struct ChatMessage: Identifiable, Codable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let content: String
    public let mediaAttachments: [ChatMessageMediaAttachment]
    public let reasoning: String?
    public let codeContext: String?
    public let billing: ChatMessageBillingContext?
    public let timestamp: Date
    public let isDraft: Bool // Marks temporary messages during streaming
    public let isCheckpoint: Bool // If true, this node is a compaction checkpoint; messages before it can be dropped from request projections.

    // Tool execution properties
    public let toolName: String?
    public var toolStatus: ToolExecutionStatus?
    public var targetFile: String?
    public var toolCallId: String? // For Tool Output messages (referencing the call)
    public let toolCalls: [AIToolCall]? // For Assistant messages (the calls themselves)

    public init(
        role: MessageRole,
        content: String,
        mediaAttachments: [ChatMessageMediaAttachment] = [],
        context: ChatMessageContentContext = ChatMessageContentContext(),
        billing: ChatMessageBillingContext? = nil,
        tool: ChatMessageToolContext = ChatMessageToolContext(),
        isDraft: Bool = false,
        isCheckpoint: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.mediaAttachments = mediaAttachments
        self.reasoning = context.reasoning
        self.codeContext = context.codeContext
        self.billing = billing
        self.timestamp = Date()
        self.isDraft = isDraft
        self.isCheckpoint = isCheckpoint
        self.toolName = tool.toolName
        self.toolStatus = tool.toolStatus
        self.targetFile = tool.targetFile
        self.toolCallId = tool.toolCallId
        self.toolCalls = tool.toolCalls.isEmpty ? nil : tool.toolCalls
    }

    public init(
        id: UUID,
        role: MessageRole,
        content: String,
        mediaAttachments: [ChatMessageMediaAttachment] = [],
        timestamp: Date,
        context: ChatMessageContentContext = ChatMessageContentContext(),
        billing: ChatMessageBillingContext? = nil,
        tool: ChatMessageToolContext = ChatMessageToolContext(),
        isDraft: Bool = false,
        isCheckpoint: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.mediaAttachments = mediaAttachments
        self.reasoning = context.reasoning
        self.codeContext = context.codeContext
        self.billing = billing
        self.timestamp = timestamp
        self.isDraft = isDraft
        self.isCheckpoint = isCheckpoint
        self.toolName = tool.toolName
        self.toolStatus = tool.toolStatus
        self.targetFile = tool.targetFile
        self.toolCallId = tool.toolCallId
        self.toolCalls = tool.toolCalls.isEmpty ? nil : tool.toolCalls
    }

    // Helper to check if this is a tool execution message
    public var isToolExecution: Bool {
        return role == .tool && toolName != nil
    }

    // MARK: Codable (backward-compat for isCheckpoint)

    enum CodingKeys: String, CodingKey {
        case id, role, content, mediaAttachments, reasoning, codeContext, billing
        case timestamp, isDraft, isCheckpoint, toolName, toolStatus, targetFile
        case toolCallId, toolCalls
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(MessageRole.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.mediaAttachments = try c.decode([ChatMessageMediaAttachment].self, forKey: .mediaAttachments)
        self.reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        self.codeContext = try c.decodeIfPresent(String.self, forKey: .codeContext)
        self.billing = try c.decodeIfPresent(ChatMessageBillingContext.self, forKey: .billing)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        self.isCheckpoint = try c.decodeIfPresent(Bool.self, forKey: .isCheckpoint) ?? false
        self.toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        self.toolStatus = try c.decodeIfPresent(ToolExecutionStatus.self, forKey: .toolStatus)
        self.targetFile = try c.decodeIfPresent(String.self, forKey: .targetFile)
        self.toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        self.toolCalls = try c.decodeIfPresent([AIToolCall].self, forKey: .toolCalls)
    }
}
