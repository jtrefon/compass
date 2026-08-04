import Foundation

public struct VectorStoreIngestionProgressEvent: Event {
    public let ingestedCount: Int
    public let totalCount: Int

    public init(ingestedCount: Int, totalCount: Int) {
        self.ingestedCount = ingestedCount
        self.totalCount = totalCount
    }
}
