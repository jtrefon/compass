import Foundation

enum LocalModelToolProvider {
    /// Tool set for local models tuned for Gemma 4.
    /// Includes read-only exploration, index-based semantic search,
    /// file mutation (with ToolLoopHandler stall detection + recovery),
    /// and shell access.
    private static let safeToolNames: Set<String> = ToolTaxonomy.execution
        .union(ToolTaxonomy.planning)
        .union(ToolTaxonomy.pinnedRules)

    static func safeTools(from allTools: [AITool]) -> [AITool] {
        allTools.filter { safeToolNames.contains($0.name) }
    }
}
