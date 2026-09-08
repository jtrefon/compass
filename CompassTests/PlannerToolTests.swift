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
        let originalPlan = TaskPlan(
            id: conversationId,
            goal: "Test goal",
            value: "Test value",
            domain: .implementation,
            mode: .coder,
            items: [
                PlanItem(id: "1", description: "Step one", purpose: "P", context: [], doneCriteria: "C", status: .pending),
                PlanItem(id: "2", description: "Step two", purpose: "P", context: [], doneCriteria: "C", status: .pending),
            ],
            createdAt: Date(),
            completedAt: nil,
            currentIndex: 0
        )
        let updatedPlan = TaskPlan(
            id: conversationId,
            goal: "Test goal",
            value: "Test value",
            domain: .implementation,
            mode: .coder,
            items: [
                PlanItem(id: "1", description: "Step one", purpose: "P", context: [], doneCriteria: "C", status: .completed, summary: "Done"),
                PlanItem(id: "2", description: "Step two", purpose: "P", context: [], doneCriteria: "C", status: .pending),
            ],
            createdAt: Date(),
            completedAt: nil,
            currentIndex: 0
        )

        await store.setPlan(conversationId: conversationId, plan: originalPlan)
        await store.setPlan(conversationId: conversationId, plan: updatedPlan)

        let storedPlan = await store.getPlan(conversationId: conversationId)

        XCTAssertNotNil(storedPlan)
        XCTAssertEqual(storedPlan?.items.count, 2)
        XCTAssertEqual(storedPlan?.items[0].status, .completed)
        XCTAssertEqual(storedPlan?.items[1].status, .pending)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testUpdateWithSamePlanDoesNotDuplicateContent() async throws {
        let store = ConversationPlanStore.shared
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await store.setProjectRoot(tempDir)

        let conversationId = "planner-update-same"
        let plan = TaskPlan(
            id: conversationId,
            goal: "Test goal",
            value: "Test value",
            domain: .implementation,
            mode: .coder,
            items: [
                PlanItem(id: "1", description: "Step one", purpose: "P", context: [], doneCriteria: "C", status: .pending),
                PlanItem(id: "2", description: "Step two", purpose: "P", context: [], doneCriteria: "C", status: .pending),
            ],
            createdAt: Date(),
            completedAt: nil,
            currentIndex: 0
        )

        await store.setPlan(conversationId: conversationId, plan: plan)
        await store.setPlan(conversationId: conversationId, plan: plan)

        let storedPlan = await store.getPlan(conversationId: conversationId)

        XCTAssertNotNil(storedPlan)
        XCTAssertEqual(storedPlan?.items.count, 2)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
