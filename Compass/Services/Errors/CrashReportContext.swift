import Foundation

public struct CrashReportContext: Sendable {
    public let operation: String

    public init(operation: String) {
        self.operation = operation
    }
}
