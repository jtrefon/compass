import Foundation

extension CodebaseIndex {
    public func listIndexedFiles(matching query: String?, limit: Int = 50, offset: Int = 0) async throws -> [String] {
        try await ensureReady()
        let absPaths = try await database.listResourcePaths(matching: query, limit: limit, offset: offset)
        return absPaths.compactMap { scopedRelativePath(from: $0) }
    }
}
