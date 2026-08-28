//
//  IndexFrameworkDetection.swift
//  Compass
//
//  Detects framework-specific exclude patterns from the shape of the project
//  root. Used by `IndexExcludePatternManager` to seed `.ide/index_exclude`
//  with framework-aware patterns on first project open (e.g. exclude
//  `wp-admin`/`wp-includes` for WordPress so the index isn't poisoned by
//  ~10k files of framework code).
//
//  Policy:
//  - Patterns returned here are included ONLY when seeding a fresh
//    `.ide/index_exclude`. Existing files are never mutated — user
//    customizations always win.
//  - User code (e.g. `wp-content/plugins/<theirs>/`,
//    `wp-content/themes/<theirs>/`) is NEVER excluded. Only stock framework
//    code shipped with the project is excluded.
//

import Foundation

enum IndexFrameworkDetection {

    /// Returns additional exclude patterns to merge into the default
    /// `index_exclude` when seeding for a new project. Empty for
    /// unrecognized projects.
    static func detectAdditionalExcludePatterns(projectRoot: URL) -> [String] {
        let fileManager = FileManager.default
        var extra: [String] = []

        // WordPress — detect via signature files/dirs at the project root.
        // The user's own code lives under `wp-content/{plugins,themes}/<name>/`;
        // the framework core under `wp-admin/` and `wp-includes/` is shipped
        // code that poisons symbol and full-text search results.
        let wpIncludes = projectRoot.appendingPathComponent("wp-includes", isDirectory: true)
        let wpConfigSample = projectRoot.appendingPathComponent("wp-config-sample.php", isDirectory: false)
        let wpAdmin = projectRoot.appendingPathComponent("wp-admin", isDirectory: true)
        let looksLikeWordPress = fileManager.fileExists(atPath: wpIncludes.path)
            || fileManager.fileExists(atPath: wpConfigSample.path)

        if looksLikeWordPress {
            if fileManager.fileExists(atPath: wpAdmin.path) {
                extra.append("wp-admin")
            }
            if fileManager.fileExists(atPath: wpIncludes.path) {
                extra.append("wp-includes")
            }
            // Stock themes ship with WordPress and aren't the user's code.
            // Exclude any theme dir whose name starts with `twenty` (the
            // WordPress convention for bundled themes: twentytwentyfive,
            // twentytwentyfour, …). User themes are untouched.
            let themesRoot = projectRoot.appendingPathComponent("wp-content/themes", isDirectory: true)
            if fileManager.fileExists(atPath: themesRoot.path),
               let entries = try? fileManager.contentsOfDirectory(
                at: themesRoot,
                includingPropertiesForKeys: nil
               ) {
                for entry in entries {
                    let name = entry.lastPathComponent
                    if name.lowercased().hasPrefix("twenty") {
                        extra.append("wp-content/themes/\(name)")
                    }
                }
            }
        }

        return extra
    }
}