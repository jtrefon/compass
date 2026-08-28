//
//  ProjectShapeSummary.swift
//  Compass
//
//  Lightweight project-type detection used by the system prompt to give the
//  model immediate orientation without needing `ls` exploration (§10 — audit).
//  Returns a short plain-text summary of the detected project type plus the
//  names of user-editable subdirectories (e.g. WordPress plugins/themes).
//
//  This is separate from `IndexFrameworkDetection` (which returns exclude
//  patterns for the indexer). The two detectors share detection criteria but
//  serve different purposes: the indexer needs patterns to skip; the prompt
//  needs a human-readable summary of the project structure.
//

import Foundation

enum ProjectShapeSummary {

    /// Returns a brief project-shape overview string for the system prompt,
    /// or nil if no frameworks/patterns are detected.
    static func generate(projectRoot: URL) -> String? {
        let fileManager = FileManager.default

        let wpIncludes = projectRoot.appendingPathComponent("wp-includes", isDirectory: true)
        let wpConfig = projectRoot.appendingPathComponent("wp-config-sample.php", isDirectory: false)
        let looksLikeWordPress = fileManager.fileExists(atPath: wpIncludes.path)
            || fileManager.fileExists(atPath: wpConfig.path)

        if looksLikeWordPress {
            return wordPressSummary(projectRoot: projectRoot, fileManager: fileManager)
        }

        return nil
    }

    // MARK: - WordPress

    private static func wordPressSummary(projectRoot: URL, fileManager: FileManager) -> String {
        var lines: [String] = []
        lines.append("## Project Shape (auto-detected)")
        lines.append("Detected: WordPress project")
        lines.append("Your code lives under wp-content/plugins/<name>/ and wp-content/themes/<name>/. Everything under wp-admin/ and wp-includes/ is WordPress core and is excluded from the project index — you do not need to read or explore it.")

        let pluginsDir = projectRoot.appendingPathComponent("wp-content/plugins", isDirectory: true)
        if fileManager.fileExists(atPath: pluginsDir.path),
           let entries = try? fileManager.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: nil) {
            let pluginNames = entries.filter { url in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }.map { $0.lastPathComponent }
            if !pluginNames.isEmpty {
                let sortedNames = pluginNames.sorted()
                let listed = sortedNames.prefix(3)
                let line = "Active plugins: \(listed.joined(separator: ", "))"
                if sortedNames.count > 3 {
                    lines.append(line + " (+\(sortedNames.count - 3) more — use `ls wp-content/plugins/` to see all)")
                } else {
                    lines.append(line)
                }
            }
        }

        let themesDir = projectRoot.appendingPathComponent("wp-content/themes", isDirectory: true)
        if fileManager.fileExists(atPath: themesDir.path),
           let entries = try? fileManager.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: nil) {
            let userThemes = entries.filter { url in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                    && !url.lastPathComponent.lowercased().hasPrefix("twenty")
            }.map { $0.lastPathComponent }
            if !userThemes.isEmpty {
                lines.append("Custom themes: \(userThemes.sorted().joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }
}