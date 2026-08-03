import Foundation

public struct LogsFollowChangedEvent: Event {
    public let follow: Bool

    public init(follow: Bool) {
        self.follow = follow
    }
}
