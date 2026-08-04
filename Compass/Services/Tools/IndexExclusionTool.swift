import Foundation

/// Lets the agent maintain the dynamic (custom) portion of the index exclude
/// list. When search / index / RAG results are dominated by dependency,
/// generated, or otherwise irrelevant files, the agent adds patterns here —
/// "assess the damage, update the list as you go". Patterns persist in
/// `<project>/.ide/index_exclude` under `[custom]` and take effect on the
/// next enumeration/reindex without user intervention.
struct IndexExclusionTool: AITool {
    let name = "exclude_from_index"
    let description = """
    Maintains the project's custom index-exclusion list (`.ide/index_exclude`, `[custom]` section).
    Use when search results, symbol lookups, or RAG retrieval are polluted by files that are not
    the user's code: vendored/third-party dirs, generated output, build artifacts, or unfamiliar
    toolchains (e.g. `vendor`, `.venv`, `node_modules` variants, `*.generated.*`). Pass `add` with
    directory names or globs to exclude them from search, indexing, and RAG ingestion; pass `remove`
    to un-exclude something previously added. Always include a short `reason` so the user can audit
    changes. The built-in defaults (`.git`, `node_modules`, `dist`, `build`, ...) are managed by the
    app and cannot be removed here.
    """

    private let projectRoot: URL
    private let eventBus: (any EventBusProtocol)?

    init(projectRoot: URL, eventBus: (any EventBusProtocol)? = nil) {
        self.projectRoot = projectRoot
        self.eventBus = eventBus
    }

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "add": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Patterns (directory names or globs) to exclude from search/index/RAG."
                ],
                "remove": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Previously added custom patterns to stop excluding."
                ],
                "reason": [
                    "type": "string",
                    "description": "Short justification for the change (shown in the result)."
                ]
            ]
        ]
    }

    func execute(arguments: ToolArguments) async throws -> String {
        let add = arguments.raw["add"] as? [String] ?? []
        let remove = arguments.raw["remove"] as? [String] ?? []
        let reason = arguments.raw["reason"] as? String ?? ""

        guard !add.isEmpty || !remove.isEmpty else {
            return "Nothing to do: pass `add` and/or `remove` with at least one pattern."
        }

        var addedPatterns: [String] = []
        var removedPatterns: [String] = []
        var lines: [String] = []
        if !add.isEmpty {
            let added = try IndexExcludePatternManager.appendCustomPatterns(projectRoot: projectRoot, patterns: add)
            addedPatterns = added
            lines.append("Added \(added.count) pattern(s): \(added.joined(separator: ", "))")
        }
        if !remove.isEmpty {
            let removed = try IndexExcludePatternManager.removeCustomPatterns(projectRoot: projectRoot, patterns: remove)
            removedPatterns = removed
            lines.append("Removed \(removed.count) pattern(s): \(removed.joined(separator: ", "))")
        }
        if !addedPatterns.isEmpty || !removedPatterns.isEmpty {
            eventBus?.publish(IndexExclusionsChangedEvent(added: addedPatterns, removed: removedPatterns))
        }

        let current = IndexExcludePatternManager.customPatterns(projectRoot: projectRoot)
        var result = lines.joined(separator: "\n")
        result += "\nCustom exclusion list now has \(current.count) pattern(s)."
        if !reason.isEmpty {
            result += "\nReason: \(reason)"
        }
        return result
    }
}
