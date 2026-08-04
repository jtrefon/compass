import Foundation

public struct LogsSourceChangedEvent: Event {
    public let sourceRawValue: String

    public init(sourceRawValue: String) {
        self.sourceRawValue = sourceRawValue
    }
}
