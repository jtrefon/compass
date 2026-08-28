import Foundation

public struct VectorStoreStatusChangedEvent: Event {
    public let entryCount: Int
    public let isLoaded: Bool
    public let isError: Bool

    public init(entryCount: Int, isLoaded: Bool, isError: Bool = false) {
        self.entryCount = entryCount
        self.isLoaded = isLoaded
        self.isError = isError
    }
}
