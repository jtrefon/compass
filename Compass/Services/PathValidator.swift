//
//  PathValidator.swift
//  Compass
//
//  Created by AI Assistant on 21/12/2025.
//

import Foundation

struct PathValidator {
    let projectRoot: URL

    private var standardizedProjectRoot: URL {
        projectRoot.standardizedFileURL
    }

    private func isWithinProjectRoot(_ url: URL) -> Bool {
        let resolvedURL = url.standardizedFileURL
        let rootURL = standardizedProjectRoot
        let resolvedPathComponents = resolvedURL.pathComponents
        let rootPathComponents = rootURL.pathComponents

        guard resolvedPathComponents.count >= rootPathComponents.count else {
            return false
        }

        return Array(resolvedPathComponents.prefix(rootPathComponents.count)) == rootPathComponents
    }

    /// Common hallucinated absolute root prefixes that models invent from training data.
    /// These are NOT actual filesystem roots — the model confuses CWD with `/workspace/`,
    /// `/home/`, etc. Strip the first component and treat the rest as relative.
    /// IMPORTANT: Do NOT include real macOS paths like `Users`, `var`, `tmp`, `private` —
    /// those are actual filesystem directories. Only include paths that don't exist on macOS.
    private let hallucinatedRoots: Set<String> = ["workspace", "home", "app", "project"]

    private func normalizePseudoRootPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return path }

        if trimmedPath == "/project" || trimmedPath == "project" {
            return "."
        }

        if trimmedPath.hasPrefix("/project/") {
            return String(trimmedPath.dropFirst("/project/".count))
        }

        if trimmedPath.hasPrefix("project/") {
            return String(trimmedPath.dropFirst("project/".count))
        }

        if trimmedPath.hasPrefix("/") {
            let withoutSlash = String(trimmedPath.dropFirst())
            let components = withoutSlash.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if let first = components.first, hallucinatedRoots.contains(first) {
                return components.dropFirst().joined(separator: "/")
            }
        }

        return trimmedPath
    }

    /// Validates and resolves a path, ensuring it's within the project root
    func validateAndResolve(_ path: String) throws -> URL {
        let normalizedPath = normalizePseudoRootPath(path)

        // Resolve to canonical path and validate sandbox
        let resolvedURL: URL
        if normalizedPath.hasPrefix("/") {
            // A genuine absolute path (a real on-disk ancestor below the first
            // component exists): accept it only when it is inside the project
            // root; reject escape attempts. Paths whose ONLY existing ancestor
            // is the first component itself — e.g. /Users/Projects/... where
            // /Users exists but /Users/Projects does not — are model-invented
            // roots and get re-rooted relative to the project, as are paths
            // with no on-disk ancestor at all (e.g. /wp-content/...).
            let absoluteURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
            let firstComponentOnly = Self.firstPathComponentURL(of: absoluteURL)
            if let existingAncestor = Self.firstExistingAncestorBelowRoot(of: absoluteURL),
               existingAncestor != firstComponentOnly {
                guard isWithinProjectRoot(existingAncestor) else {
                    throw AppError.aiServiceError("Access denied: '\(path)' is outside the project directory. All file operations are sandboxed to: \(projectRoot.path)")
                }
                resolvedURL = absoluteURL
            } else {
                let relative = String(normalizedPath.dropFirst())
                resolvedURL = projectRoot.appendingPathComponent(relative).standardizedFileURL
            }
        } else {
            resolvedURL = projectRoot.appendingPathComponent(normalizedPath).standardizedFileURL
        }

        guard isWithinProjectRoot(resolvedURL) else {
            throw AppError.aiServiceError("Access denied: '\(path)' is outside the project directory. All file operations are sandboxed to: \(projectRoot.path)")
        }

        return resolvedURL
    }

    /// Walks up from `url` (inclusive) to the filesystem root, returning the
    /// first existing path — or `nil` if nothing below `/` exists (a
    /// model-invented location).
    private static func firstExistingAncestorBelowRoot(of url: URL) -> URL? {
        var current = url
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// `/Users/Projects/file.php` → `/Users` (the first path component only).
    private static func firstPathComponentURL(of url: URL) -> URL {
        guard let first = url.pathComponents.first(where: { $0 != "/" }) else {
            return url
        }
        return URL(fileURLWithPath: "/" + first)
    }

    /// Get relative path from project root
    func relativePath(for url: URL) -> String {
        let abs = url.standardizedFileURL.path
        let root = standardizedProjectRoot.standardizedFileURL.path
        if abs == root { return "." }
        return url.relativeTo(projectRoot)
    }
}
