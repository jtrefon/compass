import Foundation

@MainActor
public protocol CodebaseIndexProtocol: Sendable {
    func start()
    func stop()

    var database: DatabaseStore { get }

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
    public func listIndexedFilesResult(matching query: String?, limit: Int, offset: Int) async
        -> Result<[String], AppError>
    {
        do {
            return .success(
                try await listIndexedFiles(matching: query, limit: limit, offset: offset))
        } catch {
            return .failure(mapToAppError(error, context: "listIndexedFiles"))
        }
    }

    public func findIndexedFilesResult(query: String, limit: Int) async -> Result<
        [IndexedFileMatch], AppError
    > {
        do {
            return .success(try await findIndexedFiles(query: query, limit: limit))
        } catch {
            return .failure(mapToAppError(error, context: "findIndexedFiles"))
        }
    }

    public func readIndexedFileResult(path: String, startLine: Int?, endLine: Int?) -> Result<
        String, AppError
    > {
        do {
            return .success(try readIndexedFile(path: path, startLine: startLine, endLine: endLine))
        } catch {
            return .failure(mapToAppError(error, context: "readIndexedFile"))
        }
    }

    public func searchIndexedTextResult(pattern: String, limit: Int) async -> Result<
        [String], AppError
    > {
        do {
            return .success(try await searchIndexedText(pattern: pattern, limit: limit))
        } catch {
            return .failure(mapToAppError(error, context: "searchIndexedText"))
        }
    }

    public func searchSymbolsResult(nameLike query: String, limit: Int) async -> Result<
        [Symbol], AppError
    > {
        do {
            return .success(try await searchSymbols(nameLike: query, limit: limit))
        } catch {
            return .failure(mapToAppError(error, context: "searchSymbols"))
        }
    }

    public func searchSymbolsWithPathsResult(
        nameLike query: String,
        limit: Int
    ) async -> Result<[SymbolSearchResult], AppError> {
        do {
            return .success(try await searchSymbolsWithPaths(nameLike: query, limit: limit))
        } catch {
            return .failure(mapToAppError(error, context: "searchSymbolsWithPaths"))
        }
    }

    public func getSummariesResult(projectRoot: URL, limit: Int) async -> Result<
        [(path: String, summary: String)], AppError
    > {
        do {
            return .success(try await getSummaries(projectRoot: projectRoot, limit: limit))
        } catch {
            return .failure(mapToAppError(error, context: "getSummaries"))
        }
    }

    public func getStatsResult() async -> Result<IndexStats, AppError> {
        do {
            return .success(try await getStats())
        } catch {
            return .failure(mapToAppError(error, context: "getStats"))
        }
    }

    private func mapToAppError(_ error: Error, context: String) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .unknown("CodebaseIndex.\(context) failed: \(error.localizedDescription)")
    }
}
