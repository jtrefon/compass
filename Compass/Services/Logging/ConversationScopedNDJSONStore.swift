import Foundation

enum ConversationScopedNDJSONStore {
    /// Project-scoped conversation directory
    /// All telemetry is now stored in project directory for proper isolation
    static func projectConversationDirectory(projectRoot: URL, conversationId: String) -> URL {
        projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
            .appendingPathComponent(conversationId, isDirectory: true)
    }

    /// Appends through the serialized `NDJSONAppendStore` — directory creation,
    /// handle reuse, and failure surfacing all live there.
    static func appendLine(
        _ line: Data,
        conversationId: String,
        fileName: String,
        projectRoot: URL?
    ) async throws {
        guard let projectRoot else {
            // No project root - cannot log (this shouldn't happen in normal operation)
            return
        }

        // Write ONLY to project directory (no Application Support)
        let projectDir = projectConversationDirectory(projectRoot: projectRoot, conversationId: conversationId)
        let projectFileURL = projectDir.appendingPathComponent(fileName)
        await NDJSONAppendStore.shared.append(line, to: projectFileURL)
    }
}
