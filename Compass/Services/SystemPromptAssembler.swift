import Foundation

struct SystemPromptAssembler {
    struct Input {
        let systemPromptOverride: String
        let hasTools: Bool
        let toolPromptMode: ToolPromptMode
        let mode: AIMode?
        let projectRoot: URL?
        let reasoningMode: ReasoningMode
        let stage: AIRequestStage?
        let includeModelReasoning: Bool
        let pinnedRules: [String]
        let repoMap: String?  // Context Access Layer L5a — condensed symbol map
    }

    func assemble(input: Input) throws -> String {
        var sections: [String] = []

        // L5a: Repo-map — condensed project symbol overview for agent mode
        if let repoMap = input.repoMap, !repoMap.isEmpty, input.mode == .agent || input.mode == .coder {
            sections.append(repoMap)
        }

        if !input.pinnedRules.isEmpty {
            sections.append("PINNED RULES (always follow, non-negotiable):\n" + input.pinnedRules.enumerated().map { i, rule in
                "\(i + 1). \(rule)"
            }.joined(separator: "\n"))
        }

        let systemPromptOverride = input.systemPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if systemPromptOverride.isEmpty {
            sections.append(try PromptRepository.shared.prompt(
                key: "System/base-system-prompt",
                projectRoot: input.projectRoot
            ))
        } else {
            sections.append(systemPromptOverride)
        }

        if input.hasTools {
            sections.append(try PromptRepository.shared.prompt(
                key: input.toolPromptMode == .fullStatic
                    ? "System/tool-system-prompt-full"
                    : "System/tool-system-prompt-concise",
                projectRoot: input.projectRoot
            ))
            // Chat: the JSON tool schemas (rendered by the chat template) ARE
            // the tool advertisement — the v3 markdown prompts duplicated the
            // schemas at ~3.9K tokens and leaked mutation/terminal tool prose
            // into a mode that cannot use them. Coder/agent keep the v3
            // reference prompts until their own slimming pass.
            // Nucleus: only registered tools get prose — saves ~2.5K vs old 12-tool set
            if input.mode != .chat {
                // Canonical nucleus prompts — no ls/glob/context unless gated
                let toolPromptKeys = [
                    "Tools/v3/read",
                    "Tools/v3/write",
                    "Tools/v3/edit",
                    "Tools/v3/search",
                    "Tools/v3/rm",
                    "Tools/v3/web_search",
                    "Tools/v3/web_fetch",
                    "Tools/v3/bash",
                    "Tools/v3/plan"
                ]
                var toolPrompts: [String] = []
                for key in toolPromptKeys {
                    if let prompt = try? PromptRepository.shared.prompt(key: key, projectRoot: input.projectRoot) {
                        toolPrompts.append(prompt)
                    }
                }
                if !toolPrompts.isEmpty {
                    sections.append("## Tool Reference\n\nEach tool below has WHAT (what it does), WHEN (when to use it), HOW (parameters and overloading), and OUTPUT (response format).\n\n" + toolPrompts.joined(separator: "\n\n---\n\n"))
                }
            }
            if let envelope = try? PromptRepository.shared.prompt(
                key: "System/tool-execution-envelope",
                projectRoot: input.projectRoot
            ) {
                sections.append(envelope)
            }
        }

        if let mode = input.mode {
            sections.append(try PromptRepository.shared.prompt(
                key: mode == .agent ? "System/mode-agent" : mode == .coder ? "System/mode-coder" : "System/mode-chat",
                projectRoot: input.projectRoot
            ))
        }

        if let projectRoot = input.projectRoot {
            // Project shape summary (§10 — audit): quick orientation before
            // any `ls` calls. Tells the model what kind of project this is
            // (WordPress, React, etc.) and which subdirectories are user code.
            if let shapeSummary = ProjectShapeSummary.generate(projectRoot: projectRoot),
               input.mode == .coder || input.mode == .agent {
                sections.append(shapeSummary)
            }

            let projectRootContextTemplate = try PromptRepository.shared.prompt(
                key: "System/project-root-context",
                projectRoot: projectRoot
            )
            sections.append(
                projectRootContextTemplate.replacingOccurrences(
                    of: "{{PROJECT_ROOT_PATH}}",
                    with: projectRoot.path
                )
            )
        }

        // The "model reasoning disabled" correction must not co-load with the
        // stage-independent optional-reasoning protocol below — for reasoning
        // modes where agent reasoning is on (`.agent`/`.modelAndAgent`), the
        // disabled correction says "don't narrate your thinking" while the
        // optional protocol demands a `<thought>` block every turn. When that
        // protocol would be active for this request, skip the disabled
        // correction; the enabled correction is kept (it explicitly defers to
        // a structured reasoning block when one is requested).
        let optionalReasoningActive = AIRequestStage.reasoningPromptKeyIfNeeded(
            reasoningMode: input.reasoningMode,
            mode: input.mode,
            stage: input.stage
        ) != nil
        let skipDisabledCorrection = optionalReasoningActive && !input.reasoningMode.includesModelReasoning
        if !skipDisabledCorrection {
            sections.append(try PromptRepository.shared.prompt(
                key: input.reasoningMode.modelReasoningPromptKey,
                projectRoot: input.projectRoot
            ))
        }

        if let reasoningPrompt = try AIRequestStage.reasoningPromptIfNeeded(
            reasoningMode: input.reasoningMode,
            mode: input.mode,
            stage: input.stage,
            projectRoot: input.projectRoot
        ) {
            sections.append(reasoningPrompt)
        }

        // Inject OS context so the agent can use platform-native tools
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        sections.append("You are running on macOS \(osVersion). For codebase exploration, use the `search` tool first — it queries the pre-built project index and returns instant, structured results. The `bash` tool is available for builds, tests, package management, server processes, and other OS-level operations.")

        return sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
