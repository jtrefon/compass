import Foundation

/// Maps legacy/provider-emitted tool names to canonical tool names.
/// Used by streaming pipeline parsers and tool resolution to normalize model
/// output (models trained on older toolsets still emit legacy names).
struct ToolAliasRegistry {
    static let shared = ToolAliasRegistry()

    private let aliases: [String: String] = [
        "read_file": "read", "view_file": "read",
        "write_file": "write", "write_files": "write", "create_file": "write",
        "patch_file": "edit", "replace_in_file": "edit",
        "delete_file": "rm",
        "list_files": "search", "list_directory": "search", "ls": "search",
        "find_file": "search", "find_files": "search", "glob": "search",
        "search_project": "search", "grep": "search", "search_files": "search",
        "run_command": "bash", "run_shell": "bash", "terminal": "bash",
        "cli-mcp-server_run_command": "bash", "cli-mcp-server_read_file": "read",
        "cli-mcp-server_write_file": "write", "cli-mcp-server_list_directory": "search",
        "web_browse": "web_fetch",
    ]

    func canonicalName(for name: String) -> String {
        aliases[name.lowercased()] ?? name.lowercased()
    }

    /// Legacy names that resolve to a canonical tool name (reverse lookup).
    /// Used to find a registered tool when the model asked for an alias.
    func legacyNames(for canonicalName: String) -> [String] {
        aliases.compactMap { legacy, canonical in
            canonical == canonicalName ? legacy : nil
        }
    }
}