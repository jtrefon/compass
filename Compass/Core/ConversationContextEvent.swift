//
//  ConversationContextEvent.swift
//  Compass
//
//  Published when conversation context size changes, so the status bar
//  can display context usage for both remote and local models.
//

import Foundation

public struct ConversationContextEvent: Event {
    /// Total character count of all messages in the conversation
    public let totalCharCount: Int
    /// Number of messages in the conversation
    public let messageCount: Int
    /// Model context window size in characters (approximate), nil if unknown
    public let contextWindowChars: Int?
    /// Compression ratio if KV cache 4-bit quantization is active, nil otherwise
    public let compressionRatio: Double?

    public init(
        totalCharCount: Int,
        messageCount: Int,
        contextWindowChars: Int? = nil,
        compressionRatio: Double? = nil
    ) {
        self.totalCharCount = totalCharCount
        self.messageCount = messageCount
        self.contextWindowChars = contextWindowChars
        self.compressionRatio = compressionRatio
    }
}
