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

    static func appendLine(
        _ line: Data,
        conversationId: String,
        fileName: String,
        projectRoot: URL?
    ) throws {
        guard let projectRoot else {
            // No project root - cannot log (this shouldn't happen in normal operation)
            return
        }

        // Write ONLY to project directory (no Application Support)
        let projectDir = projectConversationDirectory(projectRoot: projectRoot, conversationId: conversationId)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let projectFileURL = projectDir.appendingPathComponent(fileName)
        try NDJSONLogFileWriter.append(line: line, to: projectFileURL)
    }
}
