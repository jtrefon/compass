import Foundation

public struct TerminalHeightChangedEvent: Event {
    public let height: Double

    public init(height: Double) {
        self.height = height
    }
}
