//
//  IndexFileEnumerator.swift
//  Compass
//
//  Created by AI Assistant on 12/01/2026.
//

import Foundation

/// Handles project file enumeration for indexing
struct IndexFileEnumerator {

    // MARK: - Public Methods

    /// Enumerates all indexable files in a project
    static func enumerateProjectFiles(rootURL: URL, excludePatterns: [String]) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let relativePath = relativePath(from: rootURL, to: url)

            if isDirectory {
                if url.lastPathComponent == AppConstantsFileSystem.projectDirName {
                    enumerator.skipDescendants()
                    continue
                }

                if shouldExclude(relativePath: relativePath, excludePatterns: excludePatterns) {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }

            if isIndexableFile(url) && !shouldExclude(relativePath: relativePath, excludePatterns: excludePatterns) {
                results.append(url)
            }
        }
        return results
    }

    /// Enumerates all indexable files in a project (no exclude patterns)
    static func enumerateProjectFiles(rootURL: URL) -> [URL] {
        enumerateProjectFiles(rootURL: rootURL, excludePatterns: [])
    }

    // MARK: - Private Methods

    private static func isIndexableFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        return AppConstantsIndexing.allowedExtensions.contains(ext)
    }

    private static func relativePath(from root: URL, to url: URL) -> String {
        let rel = url.relativeTo(root)
        return rel == root.standardizedFileURL.path ? "" : rel
    }

    private static func shouldExclude(relativePath: String, excludePatterns: [String]) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)

        for pattern in excludePatterns {
            let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPattern.isEmpty { continue }

            if trimmedPattern.contains("*") {
                let needle = trimmedPattern.replacingOccurrences(of: "*", with: "")
                if !needle.isEmpty, normalized.contains(needle) { return true }
                continue
            }

            if trimmedPattern.contains("/") {
                let needle = trimmedPattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !needle.isEmpty, normalized.contains(needle) { return true }
                continue
            }

            if components.contains(trimmedPattern) { return true }
        }

        return false
    }
}
