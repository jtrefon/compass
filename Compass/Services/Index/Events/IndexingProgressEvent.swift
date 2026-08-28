import Foundation

public struct IndexingProgressEvent: Event {
    public let processedCount: Int
    public let totalCount: Int
    public let currentFile: URL?

    public init(processedCount: Int, totalCount: Int, currentFile: URL? = nil) {
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.currentFile = currentFile
    }
}
