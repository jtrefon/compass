import Foundation

// MARK: - Legacy v1 Protocol

public struct ToolArguments: @unchecked Sendable {
    public let raw: [String: Any]
    public init(_ raw: [String: Any]) {
        self.raw = raw
    }
}

public protocol AITool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: [String: Any] { get }
    func execute(arguments: ToolArguments) async throws -> String
}
