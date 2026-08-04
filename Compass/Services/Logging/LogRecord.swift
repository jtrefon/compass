import Foundation

public struct LogRecord: Codable, Sendable {
    public let ts: String
    public let session: String
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let metadata: [String: LogValue]?
    public let file: String
    public let function: String
    public let line: Int
}
