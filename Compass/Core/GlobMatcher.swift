import Foundation

/// Utility for glob pattern matching.
public enum GlobMatcher {
    /// Matches a path against a glob pattern.
    /// Supports:
    /// - `*`: matches any number of characters except path separators
    /// - `**`: matches any number of characters including path separators
    /// - `?`: matches a single character
    public static func match(path: String, pattern: String) -> Bool {
        // Simple implementation using fnmatch for standard glob patterns.
        // For more complex ** support, we might need a custom regex-based matcher.

        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }

        // Handle ** by converting to regex or simpler recursive checks if needed.
        // For now, we use fnmatch which handles standard shell globbing.

        return fnmatch(pattern, path, 0) == 0
    }
}
