import Foundation

public struct PatchSetEntry: Codable, Sendable {
    public let toolCallId: String
    public let kind: PatchSetChangeKind
    public let relativePath: String
    public let stagedRelativeBlobPath: String?

    public init(toolCallId: String, kind: PatchSetChangeKind, relativePath: String, stagedRelativeBlobPath: String?) {
        self.toolCallId = toolCallId
        self.kind = kind
        self.relativePath = relativePath
        self.stagedRelativeBlobPath = stagedRelativeBlobPath
    }
}
