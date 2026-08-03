//
//  IndexExcludePatternManager.swift
//  Compass
//
//  Created by AI Assistant on 12/01/2026.
//

import Foundation

/// Manages exclude patterns for indexing.
///
/// The exclude list is a HYBRID of two sources:
/// 1. **Predefined** — `IndexConfiguration.default.excludePatterns` (code):
///    git, VCS, dependency dirs, generated output. Always applied, never
///    edited by hand.
/// 2. **Dynamic** — the `[custom]` section of `<project>/.ide/index_exclude`,
///    maintained by the user AND by the agent via the `exclude_from_index`
///    tool. The agent is expected to add patterns when it observes noise
///    (vendor dirs, generated code, unknown toolchains) polluting search /
///    index / RAG results — it "assesses the damage" and updates the list as
///    projects evolve, without the user needing to know what to ignore.
///
/// File format (`.ide/index_exclude`):
/// ```
/// # [defaults] — informational mirror of the built-in list (code wins).
/// node_modules
/// ...
/// # [custom] — user/agent additions, persisted verbatim.
/// my-extra-vendor
/// ```
/// Bare lines outside any section (legacy files) are treated as custom.
struct IndexExcludePatternManager {

    private static let customSectionMarker = "[custom]"
    private static let defaultsSectionMarker = "[defaults]"
    /// Safety cap so an over-eager agent cannot grow the list without bound.
    static let maxCustomPatterns = 200

    // MARK: - Public Methods

    /// Loads the merged exclude patterns: code defaults + file custom section.
    static func loadExcludePatterns(projectRoot: URL, defaultPatterns: [String]) -> [String] {
        let fileManager = FileManager.default
        let ideDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let excludeFile = ideDir.appendingPathComponent("index_exclude", isDirectory: false)

        do {
            try fileManager.createDirectory(at: ideDir, withIntermediateDirectories: true)
        } catch {
            return defaultPatterns
        }

        if !fileManager.fileExists(atPath: excludeFile.path) {
            // Fresh seed: merge framework-detected patterns (e.g. wp-admin/
            // wp-includes for WordPress) into the defaults so the index isn't
            // poisoned by ~10k files of shipped framework code on first open.
            // Existing exclude files are NEVER mutated by detection — user
            // customizations always win.
            let detectedPatterns = IndexFrameworkDetection.detectAdditionalExcludePatterns(projectRoot: projectRoot)
            let seededPatterns: [String]
            if detectedPatterns.isEmpty {
                seededPatterns = defaultPatterns
            } else {
                seededPatterns = mergeExcludePatterns(defaultPatterns: defaultPatterns, customPatterns: detectedPatterns)
            }
            let content = defaultExcludeFileContent(defaultPatterns: seededPatterns, includeFrameworkNote: !detectedPatterns.isEmpty)
            do {
                try content.write(to: excludeFile, atomically: true, encoding: .utf8)
            } catch {
                return seededPatterns
            }
            return seededPatterns
        }

        do {
            let raw = try String(contentsOf: excludeFile, encoding: .utf8)
            let custom = parseCustomPatterns(from: raw)
            // Legacy files (pre-sections, bare patterns) are migrated to the
            // two-section format on next load so agent edits round-trip safely.
            if !raw.contains(customSectionMarker), !custom.isEmpty {
                let migrated = defaultExcludeFileContent(defaultPatterns: defaultPatterns)
                    .replacingOccurrences(of: "# (none)\n", with: custom.joined(separator: "\n") + "\n")
                try? migrated.write(to: excludeFile, atomically: true, encoding: .utf8)
            }
            return mergeExcludePatterns(defaultPatterns: defaultPatterns, customPatterns: custom)
        } catch {
            return defaultPatterns
        }
    }

    /// Appends patterns to the `[custom]` section (agent tool path). Returns
    /// the patterns actually added (skips duplicates and the cap).
    @discardableResult
    static func appendCustomPatterns(projectRoot: URL, patterns: [String]) throws -> [String] {
        let ideDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let excludeFile = ideDir.appendingPathComponent("index_exclude", isDirectory: false)
        try FileManager.default.createDirectory(at: ideDir, withIntermediateDirectories: true)

        let raw = (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? ""
        let existing = Set(parseCustomPatterns(from: raw))
        let builtIn = Set(IndexConfiguration.default.excludePatterns)
        var added: [String] = []
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard !existing.contains(trimmed), !builtIn.contains(trimmed) else { continue }
            if existing.count + added.count >= maxCustomPatterns {
                break
            }
            added.append(trimmed)
        }
        guard !added.isEmpty else { return [] }

        let updated = rewriteCustomSection(raw: raw, patterns: existing + added)
        try updated.write(to: excludeFile, atomically: true, encoding: .utf8)
        return added
    }

    /// Removes patterns from the `[custom]` section (agent tool path).
    @discardableResult
    static func removeCustomPatterns(projectRoot: URL, patterns: [String]) throws -> [String] {
        let ideDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let excludeFile = ideDir.appendingPathComponent("index_exclude", isDirectory: false)
        guard let raw = try? String(contentsOf: excludeFile, encoding: .utf8) else { return [] }

        let removeSet = Set(patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let remaining = parseCustomPatterns(from: raw).filter { !removeSet.contains($0) }
        let removed = removeSet.intersection(parseCustomPatterns(from: raw))

        let updated = rewriteCustomSection(raw: raw, patterns: remaining)
        try updated.write(to: excludeFile, atomically: true, encoding: .utf8)
        return Array(removed)
    }

    /// Current custom patterns (for tool feedback / diagnostics).
    static func customPatterns(projectRoot: URL) -> [String] {
        let ideDir = projectRoot.appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
        let excludeFile = ideDir.appendingPathComponent("index_exclude", isDirectory: false)
        guard let raw = try? String(contentsOf: excludeFile, encoding: .utf8) else { return [] }
        return parseCustomPatterns(from: raw)
    }

    // MARK: - Private Methods

    /// Parses custom patterns: everything under `[custom]`, plus bare lines in
    /// legacy files. The `[defaults]` section is informational only — code
    /// defaults always win and are merged separately.
    private static func parseCustomPatterns(from content: String) -> [String] {
        let lines = content.components(separatedBy: .newlines)
        var inDefaults = false
        var inCustom = false
        var custom: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inDefaults = line.lowercased() == defaultsSectionMarker
                inCustom = line.lowercased() == customSectionMarker
                continue
            }
            if inCustom {
                if !line.isEmpty { custom.append(line) }
            } else if !inDefaults && !line.isEmpty {
                // Legacy bare lines (pre-section files) are custom.
                custom.append(line)
            }
        }
        return custom
    }

    /// Rewrites the file keeping the defaults section (refreshed) and the
    /// given custom patterns.
    private static func rewriteCustomSection(raw: String, patterns: [String]) -> String {
        var header = """
# One pattern per line. Lines beginning with '#' are comments.
# Matching is path-based and intentionally simple; use directory names like 'node_modules' to exclude anywhere.
#
# The list is a hybrid: [defaults] mirror the built-in set (kept in code and
# always applied); [custom] holds user + agent additions and is preserved
# verbatim. The agent updates [custom] via the exclude_from_index tool.

"""
        // Preserve any pre-file comment block? Keep it simple: fresh header.
        return header + "\n" + customSectionContent(patterns: patterns)
    }

    private static func customSectionContent(patterns: [String]) -> String {
        var out = defaultsSectionMarker + "\n# Built-in defaults live in IndexConfiguration — the section below is informational.\n\n"
        out += customSectionMarker + "\n"
        if patterns.isEmpty {
            out += "# (none)\n"
        } else {
            out += patterns.joined(separator: "\n") + "\n"
        }
        return out
    }

    private static func mergeExcludePatterns(defaultPatterns: [String], customPatterns: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        merged.reserveCapacity(defaultPatterns.count + customPatterns.count)

        for pattern in defaultPatterns + customPatterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                merged.append(trimmed)
            }
        }
        return merged
    }

    private static func defaultExcludeFileContent(defaultPatterns: [String], includeFrameworkNote: Bool = false) -> String {
        var header = """
# One pattern per line.
# Lines beginning with '#' are comments.
# Matching is path-based and intentionally simple; use directory names like 'node_modules' to exclude anywhere.

"""
        if includeFrameworkNote {
            header += """
# Framework-detected patterns (auto-added on first open — safe to delete any you disagree with):
#   wp-admin, wp-includes, wp-content/themes/twenty* are WordPress core / stock themes
#   and excluded so the index reflects YOUR code under wp-content/{plugins,themes}/<name>/.

"""
        }
        return header
            + defaultsSectionMarker + "\n"
            + defaultPatterns.joined(separator: "\n") + "\n\n"
            + customSectionMarker + "\n# (none)\n"
    }
}
