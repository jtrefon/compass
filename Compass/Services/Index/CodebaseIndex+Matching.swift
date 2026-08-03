import Foundation

extension CodebaseIndex {
    public func findIndexedFiles(query: String, limit: Int = 50) async throws -> [IndexedFileMatch] {
        try await ensureReady()
        let raw = try await database.findResourceMatches(query: query, limit: max(1, min(500, limit)))
            .filter { isPathWithinProjectRoot($0.path) }
        if raw.isEmpty { return [] }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func score(for absPath: String, aiEnriched: Bool, qualityScore: Double?) -> Double {
            let rel = scopedRelativePath(from: absPath) ?? absPath
            return calculateMatchScore(relPath: rel, needle: needle, aiEnriched: aiEnriched, qualityScore: qualityScore)
        }

        let sorted = raw.sorted { left, right in
            let sa = score(for: left.path, aiEnriched: left.aiEnriched, qualityScore: left.qualityScore)
            let sb = score(for: right.path, aiEnriched: right.aiEnriched, qualityScore: right.qualityScore)
            if sa != sb { return sa > sb }
            return (scopedRelativePath(from: left.path) ?? left.path) < (scopedRelativePath(from: right.path) ?? right.path)
        }

        return sorted.compactMap { match in
            guard let relativePath = scopedRelativePath(from: match.path) else { return nil }
            return IndexedFileMatch(path: relativePath, aiEnriched: match.aiEnriched, qualityScore: match.qualityScore)
        }
    }

    private func calculateMatchScore(
        relPath: String,
        needle: String,
        aiEnriched: Bool,
        qualityScore: Double?
    ) -> Double {
        let lowerRel = relPath.lowercased()
        let base = URL(fileURLWithPath: relPath).lastPathComponent.lowercased()

        var score: Double = 0
        score += calculateBaseNameMatchScore(base: base, needle: needle)
        score += calculatePathMatchScore(lowerRel: lowerRel, needle: needle)
        score += calculateDocumentationPenalty(lowerRel: lowerRel)
        score += calculateQualityScoreBonus(aiEnriched: aiEnriched, qualityScore: qualityScore)
        return score
    }

    private func calculateBaseNameMatchScore(base: String, needle: String) -> Double {
        var score: Double = 0
        if base == needle { score += 1000 }
        if base.hasPrefix(needle) { score += 700 }
        if base.contains(needle) { score += 500 }
        return score
    }

    private func calculatePathMatchScore(lowerRel: String, needle: String) -> Double {
        var score: Double = 0
        if lowerRel == needle { score += 400 }
        if lowerRel.hasPrefix(needle) { score += 250 }
        if lowerRel.contains(needle) { score += 100 }
        return score
    }

    private func calculateDocumentationPenalty(lowerRel: String) -> Double {
        if lowerRel.hasSuffix(".md") || lowerRel.hasSuffix(".markdown") { return -50 }
        return 0
    }

    private func calculateQualityScoreBonus(aiEnriched: Bool, qualityScore: Double?) -> Double {
        var score: Double = 0
        if aiEnriched { score += 25 }
        if let qualityScore { score += qualityScore }
        return score
    }
}
