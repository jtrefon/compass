import Foundation

/// Single source of truth for tool-name categories.
/// Every toolset filter in the app derives from these sets — never hardcode
/// tool names in filters.
enum ToolTaxonomy {
    static let readOnly: Set<String> = [
        "read",
        "ls",
        "glob",
        "search",
        "context",
        "web_search",
        "web_fetch"
    ]

    /// Project-local exploration tools (read-only minus web) — the toolset the
    /// loop's researcher/analyst/architect phases expose to the model.
    static let exploration: Set<String> = readOnly.subtracting(["web_search", "web_fetch"])

    static let mutation: Set<String> = [
        "write",
        "edit",
        "rm",
        "write_file",
        "write_files",
        "create_file",
        "delete_file",
        "patch_file",
        "replace_in_file"
    ]

    static let terminal: Set<String> = ["bash", "run_command"]

    static let planning: Set<String> = ["plan"]

    static let pinnedRules: Set<String> = [
        "pinned_rule_add",
        "pinned_rule_remove",
        "pinned_rule_list"
    ]

    /// Everything the agent may execute in the tool loop (read-only +
    /// mutations + terminal).
    static let execution: Set<String> = readOnly.union(mutation).union(terminal)
}
