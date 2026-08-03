import Foundation

/// Published when an indexing operation encounters an error.
/// Subscribers can surface these to the user via status bar or diagnostics panel.
public struct IndexingErrorEvent: Event {
    public let operation: String
    public let filePath: String?
    public let errorDescription: String
    public let isCritical: Bool

    public init(operation: String, filePath: String? = nil, error: Error, isCritical: Bool = false) {
        self.operation = operation
        self.filePath = filePath
        self.errorDescription = error.localizedDescription
        self.isCritical = isCritical
    }
}
