import Foundation

/// Abstracts conversation history for components that read and extend
/// the conversation chain. The tool loop depends on this protocol,
/// not the concrete `ChatHistoryCoordinator`, enabling testability
/// with in-memory mocks.
///
/// **Design rationale:**
/// - Follows Interface Segregation: consumers see only the methods they use
/// - Follows Dependency Inversion: high-level orchestration depends on
///   this abstraction, not the concrete coordinator
/// - `ChatHistoryCoordinator` conforms via extension in its own file
@MainActor
protocol ConversationHistoryProviding: Sendable {
    /// Committed messages only (no draft, no live tool overlay).
    /// This is what the model sees as conversation history.
    var requestMessages: [ChatMessage] { get }

    /// Append a message to committed history (async).
    func append(_ message: ChatMessage) async

    /// Append a message to committed history (synchronous).
    /// Used when an async call is impossible (progress callbacks, etc.).
    func appendSync(_ message: ChatMessage)

    /// Set the in-flight draft message (streaming UI state).
    func setDraft(_ message: ChatMessage)

    /// Clear the in-flight draft.
    func clearDraft()

    /// Set a live tool execution status message (streaming UI state).
    func setLiveToolMessage(_ message: ChatMessage)

    /// Clear a live tool execution status message by tool call ID.
    func clearLiveToolMessage(_ toolCallId: String)
}
