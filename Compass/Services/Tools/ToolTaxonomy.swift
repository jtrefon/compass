import Foundation

/// Single source of truth for tool-name categories.
/// Every toolset filter in the app derives from these sets — never hardcode
/// tool names in filters.
enum ToolTaxonomy {
    // Nucleus: search replaces ls/glob, context gated, web_fetch via URLSession
    static let readOnly: Set<String> = [
        "read",
        "search",
        "web_search",
        "web_fetch"
        // context is gated (COMPASS_ENABLE_RAG) — added dynamically
    ]

    /// Project-local exploration (read-only minus web)
    static let exploration: Set<String> = ["read", "search"]

    // Only canonical mutation names — legacy aliases retired with ToolAliasRegistry
    static let mutation: Set<String> = [
        "write",
        "edit",
        "rm"
    ]

    static let terminal: Set<String> = ["bash"]

    static let planning: Set<String> = ["plan"]

    // Retired — kept empty for compatibility checks until call sites migrated
    static let pinnedRules: Set<String> = []

    /// Everything the agent may execute in the tool loop
    static let execution: Set<String> = readOnly.union(mutation).union(terminal).union(["context", "plan"])
}
