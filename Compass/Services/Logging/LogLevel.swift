import Foundation

public enum LogLevel: String, Codable, Sendable {
    case trace
    case debug
    case info
    case warning
    case error
    case critical
}
