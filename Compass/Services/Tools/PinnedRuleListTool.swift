import Foundation

public final class PinnedRuleListTool: AITool {
    public let name = "pinned_rule_list"
    public let description = "List all pinned rules with their indices. " +
        "Use before removing a rule to find the correct index."
    public var parameters: [String: Any] { ["type": "object", "properties": [:], "required": []] }

    private let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    public func execute(arguments: ToolArguments) async throws -> String {
        let rules = PinnedRulesStore.load(projectRoot: projectRoot)
        guard !rules.isEmpty else {
            return "No pinned rules. Use pinned_rule_add to create one."
        }
        return rules.enumerated().map { offset, rule in
            "\(offset + 1). \(rule)"
        }.joined(separator: "\n") + "\n\n\(rules.count)/\(PinnedRulesStore.maxCount) rules used."
    }
}
