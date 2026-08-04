import Foundation

public actor VectorStoreIngestionTracker {
    public static let shared = VectorStoreIngestionTracker()

    private var ingested: Set<String> = []
    private var persistenceURL: URL?

    public func setProjectRoot(_ root: URL) {
        let storePath = root
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("vector_store", isDirectory: true)
        persistenceURL = storePath.appendingPathComponent("ingested-conversations.json")
        load()
    }

    public func isIngested(conversationId: String) -> Bool {
        ingested.contains(conversationId)
    }

    public func markIngested(conversationId: String) {
        ingested.insert(conversationId)
        save()
    }

    public func markBatchIngested(_ ids: [String]) {
        for id in ids { ingested.insert(id) }
        save()
    }

    public var allIngested: Set<String> { ingested }

    public func clear() {
        ingested.removeAll()
        save()
    }

    private func load() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
        ingested = Set(ids)
    }

    private func save() {
        guard let url = persistenceURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(ingested)) {
            try? data.write(to: url)
        }
    }
}
