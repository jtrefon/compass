import Foundation

@MainActor
public protocol CodebaseIndexProtocol: Sendable {
    func start()
    func stop()

    var database: DatabaseManager { get }

    func setEnabled(_ enabled: Bool)
    func reindexProject()

    func listIndexedFiles(matching query: String?, limit: Int, offset: Int) async throws -> [String]
    func findIndexedFiles(query: String, limit: Int) async throws -> [IndexedFileMatch]
    func readIndexedFile(path: String, startLine: Int?, endLine: Int?) throws -> String
    func searchIndexedText(pattern: String, limit: Int) async throws -> [String]

    func searchSymbols(nameLike query: String, limit: Int) async throws -> [Symbol]
    func searchSymbolsWithPaths(nameLike query: String, limit: Int) async throws
        -> [SymbolSearchResult]
    func getSummaries(projectRoot: URL, limit: Int) async throws -> [(
        path: String, summary: String
    )]
    func getStats() async throws -> IndexStats
}

@MainActor
extension CodebaseIndexProtocol {
    private func mapToAppError(_ error: Error, context: String) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .unknown("CodebaseIndex.\(context) failed: \(error.localizedDescription)")
    }
}
