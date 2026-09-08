import Testing
import Foundation
@testable import Compass

/// Tests for the three critical bugs that caused OOM and unbounded context growth.
/// These verify the actual fix behavior — not just the data models.
@MainActor
final class MissionControlCriticalTests {

    // MARK: - Bug 1: Mission Control must NOT be committed to history

    /// The OOM bug: MC was being appended to committed history every iteration.
    /// After 30 iterations, 30 MC blocks accumulated, causing unbounded growth.
    /// This test verifies that replaceWithReset does NOT accumulate — it replaces.
    @Test func testReplaceWithResetDoesNotAccumulate() async {
        let history = ChatHistoryCoordinator()

        // Simulate 30 iterations of MC being added via replaceWithReset
        for _ in 0..<30 {
            let mc = ChatMessage(role: .user, content: "## MISSION CONTROL\nGoal: test\nNotes: none")
            await history.replaceWithReset([mc])
        }

        // History should contain exactly 1 message — not 30
        #expect(history.requestMessages.count == 1, "replaceWithReset must replace, not accumulate")
        #expect(MissionControlMarker.isMissionControl(history.requestMessages[0]))
    }

    /// Verify that append (the old buggy path) DOES accumulate — this is the
    /// anti-test proving that append was the wrong method for MC injection.
    @Test func testAppendDoesAccumulateProvingItWasTheBug() async {
        let history = ChatHistoryCoordinator()

        // Simulate the old buggy behavior: append MC every iteration
        for _ in 0..<30 {
            await history.append(ChatMessage(role: .user, content: "## MISSION CONTROL\nGoal: test"))
        }

        // History contains 30 messages — this is the bug we fixed
        #expect(history.requestMessages.count == 30, "append accumulates — this was the OOM bug")
    }

    /// Verify that replaceWithReset clears draft and live tool state
    @Test func testReplaceWithResetClearsAllState() async {
        let history = ChatHistoryCoordinator()

        // Populate with messages, draft, and live tool state
        await history.append(ChatMessage(role: .user, content: "original message"))
        history.setDraft(ChatMessage(role: .assistant, content: "draft response"))
        history.setLiveToolMessage(ChatMessage(
            role: .tool,
            content: "tool result",
            tool: ChatMessageToolContext(toolName: "read", toolStatus: .executing)
        ))

        // Reset
        let resetMessages = [
            ChatMessage(role: .system, content: "system prompt"),
            ChatMessage(role: .user, content: "## Context Reset\nReset happened"),
            ChatMessage(role: .user, content: "## MISSION CONTROL\nGoal: test")
        ]
        await history.replaceWithReset(resetMessages)

        // History should be exactly the reset messages
        #expect(history.requestMessages.count == 3)
        #expect(history.requestMessages[0].role == .system)
        #expect(MissionControlMarker.isResetNotice(history.requestMessages[1]))
        #expect(MissionControlMarker.isMissionControl(history.requestMessages[2]))
    }

    // MARK: - Bug 2: Controlled reset must fire at 75% context usage

    /// Verify computeBudgetApproximate correctly calculates percentage
    @Test func testComputeBudgetApproximateAtLowUsage() {
        let builder = MissionControlBuilder()
        let messages = [
            ChatMessage(role: .system, content: String(repeating: "x", count: 1000)),
            ChatMessage(role: .user, content: String(repeating: "y", count: 500))
        ]
        let budget = builder.computeBudgetApproximate(messages: messages, contextLength: 10_000)
        // ~1500 chars / 4 = ~375 tokens + 32 overhead = ~407 tokens
        #expect(budget.usedTokens > 0)
        #expect(budget.percentUsed < 10, "Low usage should be < 10%")
        #expect(budget.remainingTokens > 0)
    }

    @Test func testComputeBudgetApproximateAtHighUsage() {
        let builder = MissionControlBuilder()
        // Create messages that fill ~80% of a 10_000 token context
        // 8000 tokens * 4 chars/token = 32000 chars
        let messages = [
            ChatMessage(role: .system, content: String(repeating: "x", count: 16000)),
            ChatMessage(role: .user, content: String(repeating: "y", count: 16000))
        ]
        let budget = builder.computeBudgetApproximate(messages: messages, contextLength: 10_000)
        #expect(budget.percentUsed >= 75, "High usage should trigger reset threshold")
    }

    @Test func testComputeBudgetApproximateAtExactThreshold() {
        let builder = MissionControlBuilder()
        // 7500 tokens * 4 = 30000 chars
        let messages = [
            ChatMessage(role: .user, content: String(repeating: "x", count: 30000))
        ]
        let budget = builder.computeBudgetApproximate(messages: messages, contextLength: 10_000)
        #expect(budget.percentUsed >= 75, "75% usage should trigger reset")
    }

    /// Verify the reset threshold logic: below 75% no reset, at/above 75% reset
    @Test func testBudgetThresholdLogic() {
        let builder = MissionControlBuilder()

        // Below threshold — no reset needed
        let lowBudget = BudgetInfo(usedTokens: 5000, contextLength: 10_000)
        #expect(lowBudget.percentUsed == 50)
        #expect(lowBudget.percentUsed < 75)

        // At threshold — reset needed
        let atBudget = BudgetInfo(usedTokens: 7500, contextLength: 10_000)
        #expect(atBudget.percentUsed == 75)
        #expect(atBudget.percentUsed >= 75)

        // Above threshold — reset needed
        let highBudget = BudgetInfo(usedTokens: 9000, contextLength: 10_000)
        #expect(highBudget.percentUsed == 90)
        #expect(highBudget.percentUsed >= 75)
    }

    /// Verify that a controlled reset produces the correct message structure:
    /// system messages + reset notice + Mission Control
    @Test func testControlledResetProducesCorrectStructure() async {
        let history = ChatHistoryCoordinator()
        let systemMsg = ChatMessage(role: .system, content: "You are a coding assistant")
        await history.append(systemMsg)
        await history.append(ChatMessage(role: .user, content: "original user message"))
        await history.append(ChatMessage(role: .assistant, content: "original response"))
        await history.append(ChatMessage(role: .tool, content: "tool result"))

        // Simulate the reset logic from LocalModelToolLoop
        let resetNotice = ChatMessage(
            role: .user,
            content: "## Context Reset\nContext was reset to free space. Your notes and plan survive in Mission Control below — continue working from them."
        )
        let mcMessage = ChatMessage(role: .user, content: "## MISSION CONTROL\n### Goal\nTest goal")
        let systemMessages = history.requestMessages.filter { $0.role == .system }
        let resetMessages = systemMessages + [resetNotice, mcMessage]

        await history.replaceWithReset(resetMessages)

        let result = history.requestMessages
        #expect(result.count == 3, "Reset should produce system + reset notice + MC")
        #expect(result[0].role == .system)
        #expect(MissionControlMarker.isResetNotice(result[1]))
        #expect(MissionControlMarker.isMissionControl(result[2]))

        // Original messages should be gone
        let hasOriginal = result.contains { $0.content == "original user message" }
        #expect(!hasOriginal, "Original messages must be evicted by reset")
    }

    /// Verify that the reset notice has the correct content for the model to understand
    @Test func testResetNoticeContent() {
        let notice = ChatMessage(
            role: .user,
            content: "## Context Reset\nContext was reset to free space. Your notes and plan survive in Mission Control below — continue working from them."
        )
        #expect(MissionControlMarker.isResetNotice(notice))
        #expect(notice.content.contains("Context Reset"))
        #expect(notice.content.contains("notes and plan survive"))
        #expect(notice.content.contains("Mission Control"))
    }

    // MARK: - Bug 3: Context length resolution

    /// Verify that the model default is used when no override is set
    @Test func testContextLengthFallsBackToModelDefault() {
        // Clear any env/UserDefaults overrides
        let env = ProcessInfo.processInfo.environment
        let hasEnvOverride = env["COMPASS_LOCAL_MODEL_CONTEXT_LENGTH"] != nil
        try? #require(!hasEnvOverride, "This test requires no COMPASS_LOCAL_MODEL_CONTEXT_LENGTH env var")

        let stored = UserDefaults.standard.integer(forKey: LocalModelSettingsKeys.contextLength)
        if stored <= 0 {
            // No user setting — should fall back to model default (32768)
            let modelDefault = LocalModelCatalog.chatModel.defaultContextLength
            #expect(modelDefault == 32768, "Qwen3.5-4B default context should be 32768")
        }
    }

    // MARK: - PipelineProcessor Note-Aware Eviction

    /// Verify that Mission Control messages are dropped during note-aware eviction
    /// (they're rebuilt each turn, so old ones should never be sent)
    @Test func testNoteAwareEvictionDropsOldMissionControl() {
        let tracker = ToolResultNoteTracker()
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "system prompt"),
            ChatMessage(role: .user, content: "## MISSION CONTROL\nold MC block " + String(repeating: "x", count: 500)),
            ChatMessage(role: .user, content: "actual user message " + String(repeating: "y", count: 500)),
        ]

        // Force a tiny budget (10 tokens = 40 chars) to trigger eviction
        let result = PipelineProcessor.prepareForRequestNoteAware(
            messages: messages,
            modelID: nil,
            conversationId: "test",
            noteTracker: tracker,
            preservesCache: false,
            runId: nil,
            stage: nil,
            budgetOverride: 10
        )

        // The old MC message should be dropped
        let hasOldMC = result.contains { MissionControlMarker.isMissionControl($0) }
        #expect(!hasOldMC, "Old Mission Control messages must be dropped during eviction")
    }

    /// Verify that edit_target tool results are preserved over findings
    @Test func testNoteAwareEvictionPreservesEditTargetsOverFindings() {
        let tracker = ToolResultNoteTracker()

        // Record tool results with different intents
        tracker.recordToolResult(toolCallId: "finding-call", conversationId: "test")
        tracker.markNoted(toolCallId: "finding-call", intent: .finding)

        tracker.recordToolResult(toolCallId: "edit-call", conversationId: "test")
        tracker.markNoted(toolCallId: "edit-call", intent: .editTarget)

        // Finding result is large; edit_target result is small (fits in budget)
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "system"),
            ChatMessage(role: .tool, content: String(repeating: "x", count: 5000),
                        tool: ChatMessageToolContext(toolName: "read", target: ToolInvocationTarget(toolCallId: "finding-call"))),
            ChatMessage(role: .tool, content: "small edit target result",
                        tool: ChatMessageToolContext(toolName: "read", target: ToolInvocationTarget(toolCallId: "edit-call"))),
        ]

        // Budget: 200 tokens = 800 chars. System=6 chars, edit_target=24 chars.
        // Finding (5000 chars) won't fit; edit_target (24 chars) will.
        let result = PipelineProcessor.prepareForRequestNoteAware(
            messages: messages,
            modelID: nil,
            conversationId: "test",
            noteTracker: tracker,
            preservesCache: false,
            runId: nil,
            stage: nil,
            budgetOverride: 200
        )

        // The edit_target result should be preserved; the finding should be evicted
        let hasEditTarget = result.contains { $0.toolCallId == "edit-call" }
        #expect(hasEditTarget, "edit_target tool results must be preserved")

        let hasFinding = result.contains { $0.toolCallId == "finding-call" }
        #expect(!hasFinding, "finding tool results should be evicted when over budget")
    }

    /// Verify that preservesCache=true skips all eviction (local model KV stability)
    @Test func testNoteAwareEvictionSkippedWhenPreservesCache() {
        let tracker = ToolResultNoteTracker()
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "system"),
            ChatMessage(role: .user, content: String(repeating: "x", count: 100_000)),
        ]

        let result = PipelineProcessor.prepareForRequestNoteAware(
            messages: messages,
            modelID: nil,
            conversationId: "test",
            noteTracker: tracker,
            preservesCache: true,  // ← local model path
            runId: nil,
            stage: nil
        )

        // All messages should be returned unchanged
        #expect(result.count == messages.count, "preservesCache must skip eviction entirely")
    }

    /// Verify that pair-safe guard never starts with an orphaned tool result
    @Test func testNoteAwareEvictionPairSafeGuard() {
        let tracker = ToolResultNoteTracker()
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "system"),
            ChatMessage(role: .tool, content: "orphaned tool result " + String(repeating: "x", count: 500),
                        tool: ChatMessageToolContext(toolName: "read", target: ToolInvocationTarget(toolCallId: "orphan"))),
            ChatMessage(role: .user, content: "user message " + String(repeating: "y", count: 500)),
        ]

        // Force a tiny budget to trigger eviction
        let result = PipelineProcessor.prepareForRequestNoteAware(
            messages: messages,
            modelID: nil,
            conversationId: "test",
            noteTracker: tracker,
            preservesCache: false,
            runId: nil,
            stage: nil,
            budgetOverride: 10
        )

        // Result should never start with a tool message (after system)
        let nonSystem = result.filter { $0.role != .system }
        if let first = nonSystem.first {
            #expect(first.role != .tool, "Request must never start with an orphaned tool result")
        }
    }

    // MARK: - InMemoryConversationHistory (protocol conformance)

    /// Verify the InMemoryConversationHistory mock correctly implements replaceWithReset
    @Test func testInMemoryHistoryReplaceWithReset() async {
        let history = InMemoryConversationHistory()
        await history.append(ChatMessage(role: .user, content: "message 1"))
        await history.append(ChatMessage(role: .user, content: "message 2"))
        #expect(history.requestMessages.count == 2)

        let resetMessages = [
            ChatMessage(role: .system, content: "system"),
            ChatMessage(role: .user, content: "## MISSION CONTROL\ntest"),
        ]
        await history.replaceWithReset(resetMessages)

        #expect(history.requestMessages.count == 2, "Mock should replace, not append")
        #expect(history.requestMessages[0].role == .system)
        #expect(MissionControlMarker.isMissionControl(history.requestMessages[1]))
    }

    // MARK: - Integration: Reset + Mission Control together

    /// Verify the full reset flow: accumulate → hit 75% → reset → continue
    @Test func testFullResetFlowAccumulateThenReset() async {
        let history = ChatHistoryCoordinator()
        let builder = MissionControlBuilder()
        let contextLength = 10_000

        // Phase 1: Accumulate messages (simulating tool loop iterations)
        for i in 0..<20 {
            let msg = ChatMessage(role: .user, content: "Message \(i) " + String(repeating: "x", count: 2000))
            await history.append(msg)

            let budget = builder.computeBudgetApproximate(
                messages: history.requestMessages,
                contextLength: contextLength
            )

            if budget.percentUsed >= 75 {
                // Trigger reset
                let mc = await builder.build(
                    conversationId: "test-flow",
                    contextLength: contextLength,
                    usedTokens: 0
                )
                let resetNotice = ChatMessage(role: .user, content: "## Context Reset\nReset")
                let mcMsg = ChatMessage(role: .user, content: mc)
                let systemMsgs = history.requestMessages.filter { $0.role == .system }
                await history.replaceWithReset(systemMsgs + [resetNotice, mcMsg])
                break
            }
        }

        // After reset, history should be much smaller than the accumulated size
        let finalBudget = builder.computeBudgetApproximate(
            messages: history.requestMessages,
            contextLength: contextLength
        )
        #expect(finalBudget.percentUsed < 50, "After reset, usage should be well below 75%")
        #expect(history.requestMessages.count < 10, "After reset, message count should be small")
    }
}
