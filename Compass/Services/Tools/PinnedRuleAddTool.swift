import Foundation

public final class PinnedRuleAddTool: AITool {
    public let name = "pinned_rule_add"
    public let description = "Add a pinned rule the AI must always follow. " +
        "Use when the user gives a critical constraint or policy. " +
        "Maximum \(PinnedRulesStore.maxCount) rules — remove an old one first if full."
    public var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "content": [
                    "type": "string",
                    "description": "The rule text"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["content"]
        ]
    }

    private let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    public func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        guard let content = (raw["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            return "Missing 'content' argument."
        }
        var rules = PinnedRulesStore.load(projectRoot: projectRoot)
        guard rules.count < PinnedRulesStore.maxCount else {
            return "Cannot add rule: maximum \(PinnedRulesStore.maxCount) rules reached. " +
                "Remove a rule first with pinned_rule_remove."
        }
        rules.append(content)
        try PinnedRulesStore.save(rules, projectRoot: projectRoot)
        return "Rule added. \(rules.count)/\(PinnedRulesStore.maxCount) rules used."
    }
}
