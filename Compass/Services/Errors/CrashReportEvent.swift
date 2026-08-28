import Foundation

public struct CrashReportEvent: Codable, Sendable {
    public let timestamp: String
    public let session: String
    public let operation: String
    public let errorType: String
    public let errorDescription: String
    public let file: String
    public let function: String
    public let line: Int
    public let metadata: [String: String]

    private enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case session
        case operation
        case errorType
        case errorDescription
        case file
        case function
        case line
        case metadata
    }
}
