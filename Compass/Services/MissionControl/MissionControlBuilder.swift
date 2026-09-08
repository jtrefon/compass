import Foundation

/// Builds the Mission Control block for injection as the last user message.
///
/// Mission Control is a dynamic text block containing:
/// 1. Goal + Value (from TaskPlan)
/// 2. Plan + Progress (from TaskPlan)
/// 3. Working Memory (from WorkingMemoryStore)
/// 4. Key Excerpts (from SemanticCompressor — NPU-selected code chunks)
/// 5. Context Budget (live token usage with adaptive conservation guidance)
///
/// It is placed as the LAST user message before the model generates, so it
/// never invalidates the KV cache prefix (system prompt stays byte-identical).
@MainActor
final class MissionControlBuilder {
    private let workingMemoryStore: WorkingMemoryStore
    private let semanticCompressor: SemanticCompressor?

    init(
        workingMemoryStore: WorkingMemoryStore = .shared,
        semanticCompressor: SemanticCompressor? = nil
    ) {
        self.workingMemoryStore = workingMemoryStore
        self.semanticCompressor = semanticCompressor
    }

    /// Build the complete Mission Control block.
    func build(
        conversationId: String,
        contextLength: Int,
        usedTokens: Int
    ) async -> String {
        let plan = await ConversationPlanStore.shared.getPlan(conversationId: conversationId)
        let workingMemory = await workingMemoryStore.get(conversationId: conversationId)
        let keyExcerpts: [KeyExcerpt] = semanticCompressor != nil
            ? await semanticCompressor!.currentKeyExcerpts(conversationId: conversationId)
            : []
        let budget = BudgetInfo(usedTokens: usedTokens, contextLength: contextLength)

        return render(
            plan: plan,
            workingMemory: workingMemory,
            keyExcerpts: keyExcerpts,
            budget: budget
        )
    }

    /// Compute the current context budget without building the full block.
    /// Used by the eviction/reset logic to check if a reset is needed.
    func computeBudget(
        messages: [ChatMessage],
        contextLength: Int,
        approximateTokenCount: (String) -> Int
    ) -> BudgetInfo {
        var usedTokens = 0
        for message in messages {
            let content = message.role == .tool
                ? replayToolContent(from: message)
                : message.content
            usedTokens += approximateTokenCount(content) + 16
        }
        return BudgetInfo(usedTokens: usedTokens, contextLength: contextLength)
    }

    /// Compute budget using the standard ~4 chars/token approximation.
    func computeBudgetApproximate(
        messages: [ChatMessage],
        contextLength: Int
    ) -> BudgetInfo {
        computeBudget(
            messages: messages,
            contextLength: contextLength,
            approximateTokenCount: { max(1, $0.count / 4) }
        )
    }

    // MARK: - Rendering

    private func render(
        plan: TaskPlan?,
        workingMemory: WorkingMemorySnapshot,
        keyExcerpts: [KeyExcerpt],
        budget: BudgetInfo
    ) -> String {
        var sections: [String] = ["## MISSION CONTROL"]

        // Goal
        sections.append("""
        ### Goal
        \(plan?.goal ?? "No plan set — call plan(action: \"init\") to start planning.")
        Value: \(plan?.value ?? "As requested by the user")
        """)

        // Plan
        let progressString: String = {
            guard let plan, !plan.items.isEmpty else { return "0/0" }
            let completed = plan.items.filter { $0.status == .completed || $0.status == .blocked }.count
            return "\(completed)/\(plan.items.count)"
        }()
        sections.append("""
        ### Plan
        \(plan?.markdown ?? "No plan items yet.")
        Progress: \(progressString) tasks complete
        """)

        // Working Memory
        sections.append("### Working Memory\n\(workingMemory.renderForContext())")

        // Key Excerpts (only if we have them)
        if !keyExcerpts.isEmpty {
            let excerptLines = keyExcerpts.prefix(5).map { e in
                "[\(e.filePath):\(e.lineRangeDescription)] \(String(e.text.prefix(200)))"
            }
            sections.append("### Key Excerpts\n\(excerptLines.joined(separator: "\n"))")
        }

        // Context Budget
        sections.append("""
        ### Context Budget
        \(budget.usedTokens) / \(budget.contextLength) tokens (\(budget.percentUsed)% used)
        \(conservationGuidance(for: budget))
        """)

        return sections.joined(separator: "\n\n")
    }

    private func conservationGuidance(for budget: BudgetInfo) -> String {
        switch budget.percentUsed {
        case ..<25:
            return "Context is healthy. Explore freely, but take notes as you go."
        case 25..<50:
            return "Context is filling up. Be surgical with reads (limit=20-30). Take notes after every read."
        case 50..<75:
            return "Context is getting tight. Prioritize acting on your notes over new exploration."
        default:
            return "⚠️ Context nearly full. Your notes have what you need — stop exploring and start acting."
        }
    }

    private func replayToolContent(from message: ChatMessage) -> String {
        guard let envelope = ToolExecutionEnvelope.decode(from: message.content) else {
            return message.content
        }
        if let payload = envelope.payload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty {
            return payload
        }
        let fallback = envelope.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? message.content : fallback
    }
}

// MARK: - Mission Control Detection

/// Helpers for detecting and filtering Mission Control messages in history.
enum MissionControlMarker {
    static let prefix = "## MISSION CONTROL"

    /// True if the message content is a Mission Control block.
    static func isMissionControl(_ message: ChatMessage) -> Bool {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
    }

    /// True if the message content is a context reset notice.
    static func isResetNotice(_ message: ChatMessage) -> Bool {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## Context Reset")
    }
}
