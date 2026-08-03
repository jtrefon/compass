import Foundation

/// Planning tool with explicit `init` for opt-in, then `finishTask` always ends a phase.
///
/// Flow:
///   1. `init` — agent opts in → research phase (all tools available)
///   2. `finishTask` — research done, agent provides plan in summary → plan development
///   3. `finishTask` — plan ready → execution (task by task)
///   4. `finishTask` — task done → next task (repeated until all done)
///
/// Circuit breakers (any phase):
///   - `raiseQuestion` — ask user for clarification
///   - `breakOutCantContinue` — abort the plan
struct PlanTool: AITool {
    let name = "plan"
    let description = "Opt into structured planning. Call init to start — research using all tools. Then finishTask ends each phase and advances to the next. During execution, call finishTask after EACH task to record progress and reveal the next task."
    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["init", "finishTask", "raiseQuestion", "breakOutCantContinue"],
                    "description": "init: opt into planning (no summary needed). finishTask: end current phase and advance. raiseQuestion: ask user. breakOutCantContinue: abort."
                ],
                "summary": [
                    "type": "string",
                    "description": "Required for finishTask and breakOutCantContinue. During research: your proposed plan. During execution: what was done."
                ],
                "question": [
                    "type": "string",
                    "description": "Required for raiseQuestion."
                ],
                "blocker_reason": [
                    "type": "string",
                    "description": "Required for breakOutCantContinue."
                ]
            ],
            "required": ["action"]
        ]
    }

    func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        let action = raw["action"] as? String ?? ""
        let summary = raw["summary"] as? String ?? ""
        let question = raw["question"] as? String ?? ""
        let blockerReason = raw["blocker_reason"] as? String
        let conversationId = raw["_conversation_id"] as? String ?? ""

        guard ["init", "finishTask", "raiseQuestion", "breakOutCantContinue"].contains(action) else {
            return error("action must be 'init', 'finishTask', 'raiseQuestion', or 'breakOutCantContinue'.", code: "INVALID_ACTION")
        }

        // ── raiseQuestion ──
        if action == "raiseQuestion" {
            guard !question.isEmpty else { return error("question is required.", code: "MISSING_QUESTION") }
            return """
            status: question
            message: "\(question.sanitized())"
            content:
              action: "raiseQuestion"
            """
        }

        // ── init ──
        if action == "init" {
            let plan = TaskPlan(
                id: UUID().uuidString,
                goal: "Task planning session",
                value: "As requested by the user",
                domain: .implementation,
                mode: .coder,
                items: [],
                createdAt: Date(),
                completedAt: nil,
                currentIndex: 0
            )
            if !conversationId.isEmpty {
                await ConversationPlanStore.shared.setPlan(conversationId: conversationId, plan: plan)
            }
            let researchGuidance = loadPhasePrompt(defaults: ["phase": "researching"])
            return """
            status: success
            message: "\(researchGuidance)"
            content:
              action: "init"
              phase: "researching"
            """
        }

        // ── breakOutCantContinue ──
        if action == "breakOutCantContinue" {
            guard !summary.isEmpty else { return error("summary is required.", code: "MISSING_SUMMARY") }
            guard !(blockerReason?.isEmpty ?? true) else { return error("blocker_reason is required.", code: "MISSING_BLOCKER_REASON") }
            if !conversationId.isEmpty, var plan = await ConversationPlanStore.shared.getPlan(conversationId: conversationId) {
                plan.abandonAll()
                if let lastIdx = plan.items.indices.last {
                    plan.items[lastIdx].blockedReason = blockerReason
                }
                await ConversationPlanStore.shared.setPlan(conversationId: conversationId, plan: plan)
            }
            return """
            status: blocked
            message: "Plan aborted. \(summary.sanitized())"
            content:
              action: "breakOutCantContinue"
              reason: "\(blockerReason?.sanitized() ?? "")"
            """
        }

        // ── finishTask ──
        guard !summary.isEmpty else { return error("summary is required for finishTask.", code: "MISSING_SUMMARY") }

        // No conversation context — inform the agent
        guard !conversationId.isEmpty else {
            return """
            status: success
            message: "Call plan(action: \\"init\\") first to start planning."
            content:
              action: "finishTask"
              phase: "unknown"
            """
        }

        let store = ConversationPlanStore.shared

        // Fetch current plan
        guard var plan = await store.getPlan(conversationId: conversationId) else {
            return """
            status: success
            message: "No plan found. Call plan(action: \\"init\\") first to start planning."
            content:
              action: "finishTask"
              phase: "unknown"
            """
        }

        // Determine phase from plan state
        let isResearchPhase = plan.items.isEmpty
        let isExecutionPhase = plan.items.contains(where: { $0.status == .active })

        if isResearchPhase {
            // finishTask during research = agent provides the plan in summary
            // Parse summary into plan items (one task per line or as provided)
            let lines = summary.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let items: [PlanItem]
            if lines.count > 1 {
                items = lines.enumerated().map { (i, line) in
                    let clean = Self.stripNumbering(line.trimmingCharacters(in: .whitespaces))
                    return PlanItem(id: "task-\(i + 1)", description: clean, purpose: "Step in the plan", context: [], doneCriteria: "Complete and verified", status: i == 0 ? .active : .pending, summary: nil, blockedReason: nil)
                }
            } else {
                items = [PlanItem(id: "task-1", description: summary, purpose: "As planned", context: [], doneCriteria: "Complete and verified", status: .active, summary: nil, blockedReason: nil)]
            }
            plan.items = items
            plan.currentIndex = 0
            await store.setPlan(conversationId: conversationId, plan: plan)

            let first = items[0]
            let executionGuidance = loadPhasePrompt(defaults: ["phase": "executing"], replacements: [
                "TASK": first.description.sanitized(),
                "PURPOSE": first.purpose.sanitized(),
                "DONE_CRITERIA": first.doneCriteria.sanitized(),
                "PROGRESS": "0/\(items.count)"
            ])
            return """
            status: success
            message: "\(executionGuidance)"
            content:
              action: "finishTask"
              phase: "executing"
              task: "\(first.description.sanitized())"
              purpose: "\(first.purpose.sanitized())"
              done_criteria: "\(first.doneCriteria.sanitized())"
              progress: "0/\(items.count)"
            """
        }

        if isExecutionPhase {
            // finishTask during execution = complete current task, advance to next
            guard let activeIndex = plan.items.firstIndex(where: { $0.status == .active }) else {
                return error("No active task found.", code: "NO_ACTIVE_TASK")
            }

            plan.completeItem(at: activeIndex, summary: summary)

            let completed = plan.items.filter { $0.status == .completed || $0.status == .blocked }.count
            let total = plan.items.count

            guard let nextActive = plan.activateNextPending() else {
                plan.completedAt = Date()
                await store.setPlan(conversationId: conversationId, plan: plan)
                return """
                status: success
                message: "All \(total) tasks complete. Provide a final summary."
                content:
                  action: "finishTask"
                  all_done: true
                  progress: "\(completed)/\(total)"
                """
            }

            plan.currentIndex = nextActive
            await store.setPlan(conversationId: conversationId, plan: plan)

            let next = plan.items[nextActive]
            let executionGuidance = loadPhasePrompt(defaults: ["phase": "executing"], replacements: [
                "TASK": next.description.sanitized(),
                "PURPOSE": next.purpose.sanitized(),
                "DONE_CRITERIA": next.doneCriteria.sanitized(),
                "PROGRESS": "\(completed)/\(total)"
            ])
            return """
            status: success
            message: "\(executionGuidance)"
            content:
              action: "finishTask"
              phase: "executing"
              task: "\(next.description.sanitized())"
              purpose: "\(next.purpose.sanitized())"
              done_criteria: "\(next.doneCriteria.sanitized())"
              progress: "\(completed)/\(total)"
            """
        }

        // All done — nothing active and nothing pending
        return """
        status: success
        message: "All tasks complete. Provide a final summary."
        content:
          action: "finishTask"
          all_done: true
        """
    }

    /// Strip leading numbering like "1.", "2)", "3." from a task line.
    private static func stripNumbering(_ line: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"^\d+[\.\)]\s*"#, options: .anchorsMatchLines) else {
            return line
        }
        let range = NSRange(line.startIndex..., in: line)
        return regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
    }

    private func error(_ message: String, code: String) -> String {
        return """
        status: error
        message: "\(message)"
        error:
          code: \(code)
          recoverable: true
        """
    }

    /// Build a phase prompt from defaults with optional template replacements.
    /// The Tools/v2 prompt files no longer exist — defaults are the only source.
    private func loadPhasePrompt(defaults: [String: String], replacements: [String: String] = [:]) -> String {
        var result = defaults.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        for (key, value) in replacements {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}

private extension String {
    func sanitized() -> String {
        self.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(2000).description
    }
}
