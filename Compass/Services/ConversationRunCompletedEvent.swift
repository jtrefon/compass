import Foundation

public struct ConversationRunCompletedEvent: Event {
    public let runId: String

    public init(runId: String) {
        self.runId = runId
    }
}
