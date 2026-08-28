import Foundation

protocol ConversationPolicyProtocol {
    func allowedTools(
        for stage: AIRequestStage?,
        mode: AIMode,
        from availableTools: [AITool]
    ) -> [AITool]
}

final class ConversationPolicy: ConversationPolicyProtocol {
    private let readOnlyToolNames: Set<String> = ToolTaxonomy.readOnly

    private let toolLoopExecutionToolNames: Set<String> = ToolTaxonomy.execution

    func allowedTools(
        for stage: AIRequestStage?,
        mode: AIMode,
        from availableTools: [AITool]
    ) -> [AITool] {
        // First filter by mode
        let modeAllowedTools = mode.allowedTools(from: availableTools)
        
        // Then filter by stage if the mode runs the agent loop
        guard mode.isAgentic, let stage = stage else {
            return modeAllowedTools
        }
        
        // Agent mode with stage-based filtering
        switch stage {
        case .qa_tool_output_review, .qa_quality_review:
            // Read-only tools for planning and QA stages
            return filterReadOnlyTools(from: modeAllowedTools)
            
        case .initial_response:
            // Initial agent turns must be able to start execution. Stripping tools here
            // makes the live app answer conversationally and stop before any tool loop begins.
            return filterToolLoopExecutionTools(from: modeAllowedTools)
            
        case .tool_loop:
            return filterToolLoopExecutionTools(from: modeAllowedTools)

        case .final_response:
            // Preserve full tool visibility for final response handling.
            return modeAllowedTools
            
        case .warmup, .other:
            // Default to read-only for unknown stages
            return filterReadOnlyTools(from: modeAllowedTools)
        }
    }

    private func filterReadOnlyTools(from tools: [AITool]) -> [AITool] {
        tools.filter { readOnlyToolNames.contains($0.name) }
    }

    private func filterToolLoopExecutionTools(from tools: [AITool]) -> [AITool] {
        tools.filter { toolLoopExecutionToolNames.contains($0.name) }
    }
}
