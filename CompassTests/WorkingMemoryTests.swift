import Testing
import Foundation
@testable import Compass

@MainActor
final class WorkingMemoryTests {

    // MARK: - WorkingMemoryStore

    @Test func testNoteAddAndRetrieve() async throws {
        let store = WorkingMemoryStore()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)
        let conversationId = "test-\(UUID().uuidString)"

        let note = WorkingMemoryNote(
            section: "PaymentService",
            content: "Hardcoded Stripe key (CRITICAL)",
            intent: .finding
        )
        await store.add(conversationId: conversationId, note: note)

        let snapshot = await store.get(conversationId: conversationId)
        #expect(snapshot.notes.count == 1)
        #expect(snapshot.notes[0].section == "PaymentService")
        #expect(snapshot.notes[0].intent == .finding)

        await store.clear(conversationId: conversationId)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func testMaxNotesEvictionFindsOldest() async throws {
        let store = WorkingMemoryStore()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)
        let conversationId = "test-\(UUID().uuidString)"

        // Add 55 notes (max is 50)
        for i in 0..<55 {
            let note = WorkingMemoryNote(
                section: "section\(i)",
                content: "Finding \(i)",
                intent: .finding,
                timestamp: Date().addingTimeInterval(TimeInterval(i))
            )
            await store.add(conversationId: conversationId, note: note)
        }

        let snapshot = await store.get(conversationId: conversationId)
        #expect(snapshot.notes.count == 50)
        // Oldest finding notes should be evicted (findings 0-4)
        let sections = snapshot.notes.map(\.section)
        #expect(!sections.contains("section0"))
        #expect(!sections.contains("section4"))
        #expect(sections.contains("section5"))

        await store.clear(conversationId: conversationId)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func testEditTargetPreservedDuringEviction() async throws {
        let store = WorkingMemoryStore()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)
        let conversationId = "test-\(UUID().uuidString)"

        // Add 50 finding notes (at max)
        for i in 0..<50 {
            let note = WorkingMemoryNote(
                section: "finding\(i)",
                content: "Finding \(i)",
                intent: .finding,
                timestamp: Date().addingTimeInterval(TimeInterval(i))
            )
            await store.add(conversationId: conversationId, note: note)
        }

        // Add an edit_target note (should be preserved even when over max)
        let editNote = WorkingMemoryNote(
            section: "checkout.js",
            content: "Need to add validation at L23",
            intent: .editTarget
        )
        await store.add(conversationId: conversationId, note: editNote)

        let snapshot = await store.get(conversationId: conversationId)
        #expect(snapshot.notes.count == 50)
        let sections = snapshot.notes.map(\.section)
        #expect(sections.contains("checkout.js"), "edit_target should be preserved")

        await store.clear(conversationId: conversationId)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func testUpdateSectionReplacesExisting() async throws {
        let store = WorkingMemoryStore()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)
        let conversationId = "test-\(UUID().uuidString)"

        await store.add(conversationId: conversationId, note: WorkingMemoryNote(
            section: "PaymentService",
            content: "Initial finding",
            intent: .finding
        ))
        await store.updateSection(
            conversationId: conversationId,
            section: "PaymentService",
            content: "Updated finding with more detail",
            intent: .finding
        )

        let snapshot = await store.get(conversationId: conversationId)
        #expect(snapshot.notes.count == 1)
        #expect(snapshot.notes[0].content == "Updated finding with more detail")

        await store.clear(conversationId: conversationId)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func testClearSection() async throws {
        let store = WorkingMemoryStore()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)
        let conversationId = "test-\(UUID().uuidString)"

        await store.add(conversationId: conversationId, note: WorkingMemoryNote(
            section: "A", content: "Note A", intent: .finding
        ))
        await store.add(conversationId: conversationId, note: WorkingMemoryNote(
            section: "B", content: "Note B", intent: .finding
        ))
        await store.clearSection(conversationId: conversationId, section: "A")

        let snapshot = await store.get(conversationId: conversationId)
        #expect(snapshot.notes.count == 1)
        #expect(snapshot.notes[0].section == "B")

        await store.clear(conversationId: conversationId)
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func testEditTargetSections() async throws {
        let store = WorkingMemoryStore()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)
        let conversationId = "test-\(UUID().uuidString)"

        await store.add(conversationId: conversationId, note: WorkingMemoryNote(
            section: "file1.swift", content: "Finding", intent: .finding
        ))
        await store.add(conversationId: conversationId, note: WorkingMemoryNote(
            section: "file2.swift", content: "Edit target", intent: .editTarget
        ))

        let editTargets = await store.editTargetSections(conversationId: conversationId)
        #expect(editTargets == ["file2.swift"])

        await store.clear(conversationId: conversationId)
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - ToolResultNoteTracker

    @Test func testNoteTrackerEvictableAfterFinding() async throws {
        let tracker = ToolResultNoteTracker()
        tracker.recordToolResult(toolCallId: "call-1", conversationId: "conv-1")
        // Before noting — not evictable (keep until noted)
        #expect(!tracker.isEvictable(toolCallId: "call-1"))
        tracker.markNoted(toolCallId: "call-1", intent: .finding)
        // After noting as finding — evictable
        #expect(tracker.isEvictable(toolCallId: "call-1"))
    }

    @Test func testNoteTrackerNotEvictableForEditTarget() async throws {
        let tracker = ToolResultNoteTracker()
        tracker.recordToolResult(toolCallId: "call-2", conversationId: "conv-1")
        tracker.markNoted(toolCallId: "call-2", intent: .editTarget)
        #expect(!tracker.isEvictable(toolCallId: "call-2"))
        #expect(tracker.isEditTarget(toolCallId: "call-2"))
    }

    @Test func testNoteTrackerEditCompleteDowngradesToFinding() async throws {
        let tracker = ToolResultNoteTracker()
        tracker.recordToolResult(toolCallId: "call-3", conversationId: "conv-1")
        tracker.markNoted(toolCallId: "call-3", intent: .editTarget)
        #expect(!tracker.isEvictable(toolCallId: "call-3"))
        tracker.markEditComplete(toolCallId: "call-3")
        #expect(tracker.isEvictable(toolCallId: "call-3"))
    }

    @Test func testNoteTrackerUntrackedIsEvictable() async throws {
        let tracker = ToolResultNoteTracker()
        // Untracked tool call — evictable by default
        #expect(tracker.isEvictable(toolCallId: "unknown-call"))
    }

    // MARK: - SemanticChunker

    @Test func testChunkSwiftByFunctionBoundary() {
        let code = """
        import Foundation

        struct Foo {
            let bar: Int
        }

        func doSomething() {
            print("hello")
        }

        func anotherThing() -> Int {
            return 42
        }
        """
        let chunks = SemanticChunker.chunk(code, filePath: "test.swift")
        #expect(chunks.count >= 3, "Should split at function/struct boundaries")
        // The struct should be in one of the chunks
        let structChunk = chunks.first { $0.text.contains("struct Foo") }
        #expect(structChunk != nil, "A chunk should contain the struct")
        // The functions should be in separate chunks
        let doSomethingChunk = chunks.first { $0.text.contains("func doSomething") }
        #expect(doSomethingChunk != nil, "A chunk should contain doSomething")
        let anotherThingChunk = chunks.first { $0.text.contains("func anotherThing") }
        #expect(anotherThingChunk != nil, "A chunk should contain anotherThing")
    }

    @Test func testChunkPHPIfFunctionBoundary() {
        let code = """
        <?php

        function processPayment($amount) {
            return $amount;
        }

        function sendNotification($msg) {
            wp_mail("admin", $msg);
        }
        """
        let chunks = SemanticChunker.chunk(code, filePath: "test.php")
        #expect(chunks.count >= 2, "Should split at PHP function boundaries")
    }

    @Test func testChunkTextByFixedSize() {
        let text = String(repeating: "Line content here\n", count: 25)
        let chunks = SemanticChunker.chunk(text, filePath: "readme.txt")
        #expect(chunks.count == 3, "25 lines / 10-line windows = 3 chunks")
        #expect(chunks[0].lineStart == 1)
        #expect(chunks[0].lineEnd == 10)
    }

    @Test func testLanguageDetectionByExtension() {
        #expect(SemanticChunker.detectLanguage(filePath: "test.swift", content: "") == .swift)
        #expect(SemanticChunker.detectLanguage(filePath: "test.php", content: "") == .php)
        #expect(SemanticChunker.detectLanguage(filePath: "test.py", content: "") == .python)
        #expect(SemanticChunker.detectLanguage(filePath: "test.js", content: "") == .javascript)
        #expect(SemanticChunker.detectLanguage(filePath: "test.ts", content: "") == .typescript)
        #expect(SemanticChunker.detectLanguage(filePath: "test.md", content: "") == .markdown)
    }

    @Test func testLanguageDetectionByContent() {
        #expect(SemanticChunker.detectLanguage(filePath: nil, content: "<?php echo 'hi'; ?>") == .php)
        #expect(SemanticChunker.detectLanguage(filePath: nil, content: "import SwiftUI") == .swift)
        #expect(SemanticChunker.detectLanguage(filePath: nil, content: "plain text content") == .unknown)
    }

    // MARK: - MissionControlBuilder

    @Test func testMissionControlRenderWithEmptyState() async throws {
        let builder = MissionControlBuilder()
        let block = await builder.build(
            conversationId: "test-empty",
            contextLength: 30_000,
            usedTokens: 1000
        )
        #expect(block.contains("## MISSION CONTROL"))
        #expect(block.contains("No plan set"))
        #expect(block.contains("No notes yet"))
        #expect(block.contains("1000 / 30000 tokens"))
        #expect(block.contains("Context is healthy"))
    }

    @Test func testMissionControlBudgetGuidance() async throws {
        let builder = MissionControlBuilder()

        let block25 = await builder.build(conversationId: "t1", contextLength: 10_000, usedTokens: 2_500)
        #expect(block25.contains("Context is filling up"))

        let block50 = await builder.build(conversationId: "t2", contextLength: 10_000, usedTokens: 5_500)
        #expect(block50.contains("Context is getting tight"))

        let block75 = await builder.build(conversationId: "t3", contextLength: 10_000, usedTokens: 8_000)
        #expect(block75.contains("Context nearly full"))
    }

    @Test func testMissionControlMarkerDetection() {
        let mcMsg = ChatMessage(role: .user, content: "## MISSION CONTROL\n### Goal\nDo something")
        #expect(MissionControlMarker.isMissionControl(mcMsg))

        let resetMsg = ChatMessage(role: .user, content: "## Context Reset\nContext was reset to free space.")
        #expect(MissionControlMarker.isResetNotice(resetMsg))

        let normalMsg = ChatMessage(role: .user, content: "Please review my code")
        #expect(!MissionControlMarker.isMissionControl(normalMsg))
        #expect(!MissionControlMarker.isResetNotice(normalMsg))
    }

    // MARK: - WorkingMemorySnapshot Rendering

    @Test func testSnapshotRenderForContext() {
        let snapshot = WorkingMemorySnapshot(notes: [
            WorkingMemoryNote(section: "PaymentService", content: "Hardcoded key (CRITICAL)", intent: .finding),
            WorkingMemoryNote(section: "Architecture", content: "3 hooks, REST base /v1/", intent: .finding),
        ])
        let rendered = snapshot.renderForContext()
        #expect(rendered.contains("PaymentService"))
        #expect(rendered.contains("Hardcoded key"))
        #expect(rendered.contains("Architecture"))
    }

    @Test func testSnapshotRenderEmpty() {
        let snapshot = WorkingMemorySnapshot()
        let rendered = snapshot.renderForContext()
        #expect(rendered.contains("No notes yet"))
    }
}
