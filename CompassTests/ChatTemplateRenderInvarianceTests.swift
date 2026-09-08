import XCTest
import Jinja
@testable import Compass

/// Guard for the render-invariance requirement of the Qwen3.5 runtime chat
/// template (see `LocalModelFileStore.qwen35JSONOnlyChatTemplate`).
///
/// **The invariant:** the rendered token stream for a message prefix must not
/// depend on what comes after it. The upstream Qwen3 template replayed
/// `<think>` reasoning only for assistant messages after the last real user
/// message — appending a user message (finalize prompt, user reply) re-rendered
/// every prior assistant message and diverged the KV-cache prefix, forcing
/// full 40K+ token re-prefills at every turn boundary (measured 274s in live
/// telemetry, 2026-09-01).
///
/// These tests render the SAME history twice — once ending with a tool result
/// (tool-loop iteration) and once ending with a user message (finalize/user
/// turn) — and assert the shared prefix renders identically.
final class ChatTemplateRenderInvarianceTests: XCTestCase {

    private let templateString = LocalModelFileStore.qwen35JSONOnlyChatTemplate

    // MARK: - Fixtures

    /// A tool-loop history: system → user → assistant(tool call, reasoning) → tool result.
    private func loopMessages(
        userContent: String = "Fix the bug in TransactionHandler.php",
        reasoning: String = "I should read the file first to understand the structure.",
        assistantContent: String = "",
        toolResult: String = "<?php class TransactionHandler {}"
    ) -> [[String: Any?]] {
        [
            ["role": "system", "content": "You are a coding agent."],
            ["role": "user", "content": userContent],
            [
                "role": "assistant",
                "content": assistantContent,
                "reasoning_content": reasoning,
                "tool_calls": [[
                    "function": [
                        "name": "read",
                        "arguments": ["path": "TransactionHandler.php"]
                    ]
                ]]
            ],
            ["role": "tool", "content": toolResult]
        ]
    }

    // MARK: - Rendering

    private func render(_ messages: [[String: Any?]], addGenerationPrompt: Bool) throws -> String {
        let template = try Template(templateString)
        return try template.render([
            "messages": try Value(any: messages),
            "add_generation_prompt": .boolean(addGenerationPrompt),
            "enable_thinking": .boolean(true)
        ])
    }

    /// Renders `history` (generation prompt off) — the pure message block.
    /// THE invariant: rendering the shared prefix must be byte-identical no
    /// matter what messages are appended after it.
    private func assertPrefixStable(
        history: [[String: Any?]],
        appended: [[String: Any?]],
        context: StaticString = #function
    ) throws {
        let base = try render(history, addGenerationPrompt: false)
        let extended = try render(history + appended, addGenerationPrompt: false)
        XCTAssertTrue(
            extended.hasPrefix(base),
            """
            [\(context)] RENDER INSTABILITY: appending \(appended.count) message(s) \
            changed how the existing \(history.count) messages render. This diverges \
            the KV-cache prefix and forces a full re-prefill at turn boundaries.
            --- base (prefix) ---
            \(base.suffix(300))
            --- extended ---
            \(extended.suffix(300))
            """
        )
    }

    // MARK: - The invariant

    /// Tool-loop iteration (ends with tool result) vs user turn (finalize/user
    /// reply appended): the shared prefix must render identically.
    func testPrefixStableWhenUserMessageFollowsToolResult() throws {
        try assertPrefixStable(
            history: loopMessages(),
            appended: [["role": "user", "content": "Produce a final answer now."]]
        )
    }

    /// Deeper loop (two tool rounds) — same property at the second boundary.
    func testPrefixStableAcrossSecondToolRound() throws {
        var history = loopMessages()
        history.append([
            "role": "assistant",
            "content": "",
            "reasoning_content": "The file exists; now search for the handler usage.",
            "tool_calls": [[
                "function": [
                    "name": "search",
                    "arguments": ["query": "TransactionHandler"]
                ]
            ]]
        ])
        history.append(["role": "tool", "content": "matches: 3"])
        try assertPrefixStable(
            history: history,
            appended: [["role": "user", "content": "Summarize what you found."]]
        )
    }

    /// A plain assistant answer (no tool calls) followed by a user reply —
    /// the exact scenario measured in telemetry (user reply after agent finish).
    func testPrefixStableWhenUserRepliesAfterAssistantAnswer() throws {
        var history = loopMessages()
        history.append([
            "role": "assistant",
            "content": "The handler was missing; I recreated it.",
            "reasoning_content": "The result shows the fix is complete."
        ])
        try assertPrefixStable(
            history: history,
            appended: [["role": "user", "content": "Great, now add tests."]]
        )
    }

    // MARK: - Reasoning replay behavior

    /// Assistant reasoning must be replayed as a think block even when the
    /// conversation continues past it (the old template stripped these).
    func testAssistantReasoningIsReplayedUnconditionally() throws {
        let rendered = try render(loopMessages(), addGenerationPrompt: false)
        XCTAssertTrue(
            rendered.contains("<think>\nI should read the file first to understand the structure.\n</think>"),
            "Assistant reasoning_content must be replayed as <think>…</think> regardless of position."
        )
    }

    /// Assistants without reasoning render an empty think block — matching the
    /// raw generation shape (`<think>\n\n</think>\n\n`) so the KV prefix keeps
    /// overlapping the model's own generated tokens.
    func testAssistantWithoutReasoningRendersEmptyThinkBlock() throws {
        let messages: [[String: Any?]] = [
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "Hello!"]
        ]
        let rendered = try render(messages, addGenerationPrompt: false)
        XCTAssertTrue(
            rendered.contains("<|im_start|>assistant\n<think>\n\n</think>\n\nHello!"),
            "An assistant message without reasoning must render an empty think block so the rendered tokens keep matching the raw generated stream."
        )
    }

    /// Generation prompt must end with the open think tag (thinking enabled).
    func testGenerationPromptOpensThinkBlock() throws {
        let rendered = try render(loopMessages(), addGenerationPrompt: true)
        XCTAssertTrue(rendered.hasSuffix("<|im_start|>assistant\n<think>\n"))
    }
}
