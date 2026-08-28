import Foundation

public struct ErrorHandlingContext {
    public let operation: String
    public let file: String
    public let function: String
    public let line: Int

    public init(operation: String, file: String, function: String, line: Int) {
        self.operation = operation
        self.file = file
        self.function = function
        self.line = line
    }
}
