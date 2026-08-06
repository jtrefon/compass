import Foundation

enum LocalModelToolProvider {
    /// Tool set for the fixed local chat model (Qwen3.5-4B): execution +
    /// planning + pinned rules. Mutation tools flow through the shared
    /// ToolScheduler/TimeoutCenter machinery like the cloud path.
    private static let safeToolNames: Set<String> = ToolTaxonomy.execution
        .union(ToolTaxonomy.planning)
        .union(ToolTaxonomy.pinnedRules)

    static func safeTools(from allTools: [AITool]) -> [AITool] {
        allTools.filter { safeToolNames.contains($0.name) }
    }
}
