import Foundation

public final class PinnedRuleRemoveTool: AITool {
    public let name = "pinned_rule_remove"
    public let description = "Remove a pinned rule by index. " +
        "Use when a rule is obsolete and needs to be replaced. " +
        "List rules first with pinned_rule_list to see indices."
    public var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "index": [
                    "type": "integer",
                    "description": "The 1-based index of the rule to remove (as shown by pinned_rule_list)"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["index"]
        ]
    }

    private let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    public func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        guard let index = raw["index"] as? Int else {
            return "Missing or invalid 'index' argument."
        }
        var rules = PinnedRulesStore.load(projectRoot: projectRoot)
        guard index >= 1, index <= rules.count else {
            return "Invalid index \(index). Use pinned_rule_list to see valid indices (1-\(rules.count))."
        }
        let removed = rules.remove(at: index - 1)
        try PinnedRulesStore.save(rules, projectRoot: projectRoot)
        return "Removed rule \(index): \"\(removed)\". \(rules.count)/\(PinnedRulesStore.maxCount) rules used."
    }
}
