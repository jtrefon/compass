import Foundation

extension CodebaseIndex {
    nonisolated static func makeEnrichmentPrompt(path: String, content: String) -> String {
        return """
        Analyze the following source file and provide a quality score and a concise summary.

        The summary should be 1-2 sentences describing the main purpose of the file " +
                "or the primary class/struct it contains. Focus on \"what\" and \"why\", not just \"how\".

        Return ONLY a single line JSON object like:
        {"score": 85, "summary": "Manages the SQLite database for the " +
                "codebase index, handling table creation and thread-safe operations."}

        Where score is an integer from 0 to 100.

        File: \(path)

        Code:
        \(content)
        """
    }

    nonisolated static func parseEnrichmentResponse(from content: String?) -> (score: Int, summary: String?)? {
        guard let content else { return nil }
        guard let data = content.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let score: Int
        if let intScore = obj["score"] as? Int {
            score = max(0, min(100, intScore))
        } else if let doubleScore = obj["score"] as? Double {
            score = max(0, min(100, Int(doubleScore.rounded())))
        } else {
            score = 0
        }

        let summary = obj["summary"] as? String
        return (score, summary)
    }

    nonisolated static func isIndexableFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        return AppConstantsIndexing.allowedExtensions.contains(ext)
    }

    nonisolated static func isAIEnrichableFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        return AppConstantsIndexing.aiEnrichableExtensions.contains(ext)
    }

    nonisolated static func resolveIndexDirectory(projectRoot: URL, storageDirectoryPath: String? = nil) -> URL {
        let fileManager = FileManager.default

        if let storageDirectoryPath,
           !storageDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let explicitDirectoryURL = URL(fileURLWithPath: storageDirectoryPath, isDirectory: true)
            do {
                try fileManager.createDirectory(at: explicitDirectoryURL, withIntermediateDirectories: true)
                return explicitDirectoryURL
            } catch {
                // fall through to default/fallback resolution
            }
        }

        let ideDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName)
        let indexDir = ideDir.appendingPathComponent("index")

        do {
            try fileManager.createDirectory(at: indexDir, withIntermediateDirectories: true)
            return indexDir
        } catch {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let fallbackRoot = (appSupport ?? fileManager.temporaryDirectory)
                .appendingPathComponent("Compass")
                .appendingPathComponent("index")
                .appendingPathComponent(String(projectRoot.path.hashValue))

            try? fileManager.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
            return fallbackRoot
        }
    }

    nonisolated static func indexDatabaseURL(projectRoot: URL) -> URL {
        let dir = resolveIndexDirectory(projectRoot: projectRoot)
        return dir.appendingPathComponent("codebase.sqlite")
    }
}
