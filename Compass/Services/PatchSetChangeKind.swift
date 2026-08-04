import Foundation

public enum PatchSetChangeKind: String, Codable, Sendable {
    case write
    case delete
    case replace
    case create
}
