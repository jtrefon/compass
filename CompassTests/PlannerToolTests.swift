import XCTest

@testable import Compass

final class PlannerToolTests: XCTestCase {

    func testUpdateReplacesExistingPlanInsteadOfAppending() async throws {
        let store = ConversationPlanStore.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)

        let conversationId = "planner-update-replace"
        let originalPlan = """
        # Implementation Plan

        - [ ] Step one
        - [ ] Step two
        """
        let updatedPlan = """
        # Implementation Plan

        - [x] Step one
        - [ ] Step two
        """

        await store.set(conversationId: conversationId, plan: originalPlan)
        await store.set(conversationId: conversationId, plan: updatedPlan)

        let storedPlan = await store.get(conversationId: conversationId)

        XCTAssertEqual(storedPlan, updatedPlan)
        XCTAssertFalse(storedPlan?.contains("- [ ] Step one\n- [ ] Step two\n\n# Implementation Plan") ?? false)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUpdateWithSamePlanDoesNotDuplicateContent() async throws {
        let store = ConversationPlanStore.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)

        let conversationId = "planner-update-same"
        let plan = """
        # Implementation Plan

        - [ ] Step one
        - [ ] Step two
        """

        await store.set(conversationId: conversationId, plan: plan)
        await store.set(conversationId: conversationId, plan: plan)

        let storedPlan = await store.get(conversationId: conversationId)

        XCTAssertEqual(storedPlan, plan)
        XCTAssertEqual(storedPlan?.components(separatedBy: "# Implementation Plan").count, 2)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
