import Foundation

extension Notification.Name {
    static let inlineCompletionStatusDidChange = Notification.Name("InlineCompletionStatusDidChange")
}

public enum InlineCompletionStatus: String, Sendable {
    case idle
    case generating
    case noSuggestion
}
