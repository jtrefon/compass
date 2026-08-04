import Foundation

extension CodebaseIndex {
    private struct SymbolKindStats {
        let classCount: Int
        let structCount: Int
        let enumCount: Int
        let protocolCount: Int
        let functionCount: Int
        let variableCount: Int
    }

    public func getStats() async throws -> IndexStats {
        try await ensureReady()
        let counts = try await database.getIndexStatsCounts()
        // Single enumeration pass for both counts — the previous two full
        // walks ran every 2s from the status-bar poll.
        let allFiles = IndexFileEnumerator.enumerateProjectFiles(
            rootURL: projectRoot,
            excludePatterns: excludePatterns
        )
        let totalProjectFileCount = allFiles.count
        let aiEnrichableProjectFileCount = allFiles.filter { Self.isAIEnrichableFile($0) }.count

        let scoped = await loadScopedStats(fallbackIndexedCount: counts.indexedResourceCount)
        let kindCounts = try await database.getSymbolKindCounts()
        let avgQuality = try await database.getAverageQualityScore()
        let metadata = databaseMetadata()
        let kindStats = symbolKindStats(kindCounts)

        return IndexStats(
            indexedResourceCount: scoped.indexedCount,
            aiEnrichedResourceCount: scoped.aiEnrichedCount,
            aiEnrichableProjectFileCount: aiEnrichableProjectFileCount,
            totalProjectFileCount: totalProjectFileCount,
            symbolCount: counts.symbolCount,
            classCount: kindStats.classCount,
            structCount: kindStats.structCount,
            enumCount: kindStats.enumCount,
            protocolCount: kindStats.protocolCount,
            functionCount: kindStats.functionCount,
            variableCount: kindStats.variableCount,
            databaseSizeBytes: metadata.sizeBytes,
            databasePath: dbPath,
            isDatabaseInWorkspace: metadata.isInWorkspace,
            averageQualityScore: avgQuality,
            averageAIQualityScore: scoped.avgAIQuality
        )
    }

    private func loadScopedStats(
        fallbackIndexedCount: Int
    ) async -> (indexedCount: Int, aiEnrichedCount: Int, avgAIQuality: Double) {
        let allowed = AppConstantsIndexing.allowedExtensions
        let indexedCount = (try? await database.getIndexedResourceCountScoped(
            projectRoot: projectRoot,
            allowedExtensions: allowed
        )) ?? fallbackIndexedCount
        let aiEnrichedCount = (try? await database.getAIEnrichedResourceCountScoped(
            projectRoot: projectRoot,
            allowedExtensions: allowed
        )) ?? 0
        let avgAIQuality = (try? await database.getAverageAIQualityScoreScoped(
            projectRoot: projectRoot,
            allowedExtensions: allowed
        )) ?? 0
        return (indexedCount, aiEnrichedCount, avgAIQuality)
    }

    private func databaseMetadata() -> (sizeBytes: Int64, isInWorkspace: Bool) {
        let sizeBytes: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: dbPath)
            sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            sizeBytes = 0
        }

        let workspaceIndexDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName).appendingPathComponent("index")
        let dbURL = URL(fileURLWithPath: dbPath)
        let isInWorkspace = dbURL.path.hasPrefix(workspaceIndexDir.path)

        return (sizeBytes, isInWorkspace)
    }

    public func getSummaries(projectRoot: URL, limit: Int) async throws -> [(path: String, summary: String)] {
        try await ensureReady()
        let paths = try await database.listResourcePaths(matching: nil, limit: limit, offset: 0)
        return paths.map { ($0, "") }
    }

    private func symbolKindStats(
        _ kindCounts: [String: Int]
    ) -> SymbolKindStats {
        return SymbolKindStats(
            classCount: kindCounts[SymbolKind.class.rawValue] ?? 0,
            structCount: kindCounts[SymbolKind.struct.rawValue] ?? 0,
            enumCount: kindCounts[SymbolKind.enum.rawValue] ?? 0,
            protocolCount: kindCounts[SymbolKind.protocol.rawValue] ?? 0,
            functionCount: kindCounts[SymbolKind.function.rawValue] ?? 0,
            variableCount: kindCounts[SymbolKind.variable.rawValue] ?? 0
        )
    }
}
