import Foundation

public struct ProjectReindexCompletedEvent: Event {
    public let indexedCount: Int
    public let duration: TimeInterval

    public init(indexedCount: Int, duration: TimeInterval) {
        self.indexedCount = indexedCount
        self.duration = duration
    }
}
