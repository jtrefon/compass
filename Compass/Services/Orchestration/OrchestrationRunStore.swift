import Foundation

actor OrchestrationRunStore {
    static let shared = OrchestrationRunStore()

    private var projectRoot: URL?

    func setProjectRoot(_ root: URL) {
        projectRoot = root
    }

    func appendSnapshot(_ snapshot: OrchestrationRunSnapshot) async throws {
        guard let url = snapshotFileURL(conversationId: snapshot.conversationId, runId: snapshot.runId) else {
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try appendJSONLine(data: data, url: url)
    }

    private func appendJSONLine(data: Data, url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()
        } else {
            var newData = data
            newData.append(Data("\n".utf8))
            try newData.write(to: url, options: [.atomic])
        }
    }

    private func snapshotFileURL(conversationId: String, runId: String) -> URL? {
        guard let projectRoot else { return nil }
        return projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("orchestration", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(conversationId, isDirectory: true)
            .appendingPathComponent("\(runId).jsonl")
    }
}
