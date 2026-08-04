import Foundation

public enum LogCategory: String, Codable, Sendable {
    case app
    case conversation
    case ai
    case tool
    case eventBus
    case error
    case localModel
    case rag
}
