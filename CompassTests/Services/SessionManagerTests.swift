//
//  SessionManagerTests.swift
//  CompassTests
//
//  Created on 01/09/2026.
//
//  Regression coverage for the session registry:
//  - boot hydration from the per-project manifest (fast, lazy snapshot decode)
//  - registry self-heal when the manifest/order is broken or orphaned
//  - empty-overwrite guard (boot-order regression that wiped disk sessions)
//  - close/recover/discard lifecycle + archive metadata (date/size)
//  - project-scoped registries (no cross-project id leakage)

import XCTest
import Combine
@testable import Compass

@MainActor
final class SessionManagerTests: XCTestCase {

    private var projectRoot: URL!
    private var historyCoordinator: ChatHistoryCoordinator!
    private let manifestStore = SessionManifestStore()

    override func setUp() async throws {
        try await super.setUp()
        let defaults = AppRuntimeEnvironment.userDefaults
        defaults.removeObject(forKey: "SessionManager.sessionOrder")
        defaults.removeObject(forKey: "SessionManager.selectedId")
        defaults.removeObject(forKey: "SessionManager.closedRegistry")
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        historyCoordinator = ChatHistoryCoordinator()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectRoot)
        projectRoot = nil
        historyCoordinator = nil
        try await super.tearDown()
    }

    // MARK: - Helpers (call production code — Rule: harness orchestrates)

    private func makeSnapshot(
        id: String,
        messages: [String],
        subject: String,
        updatedAt: Date,
        closedAt: Date? = nil,
        mode: AIMode = .chat
    ) {
        let snapshot = SessionManager.SessionSnapshot(
            messages: messages.map { ChatMessage(role: .user, content: $0) },
            mode: mode,
            input: "",
            subject: subject,
            createdAt: updatedAt.addingTimeInterval(-3600),
            updatedAt: updatedAt,
            closedAt: closedAt
        )
        SessionManager.SessionSnapshot.saveToDisk(sessionId: id, snapshot: snapshot, projectRoot: projectRoot)
    }

    private func makeManifest(
        order: [String],
        archivedIds: [String] = [],
        selectedId: String? = nil,
        sessions: [String: SessionManifest.Entry]? = nil
    ) {
        var manifest = SessionManifest()
        if let sessions {
            manifest.sessions = sessions
        }
        for id in order + archivedIds {
            if manifest.sessions[id] == nil, let snapshot = SessionManager.SessionSnapshot.loadFromDisk(sessionId: id, projectRoot: projectRoot) {
                manifest.sessions[id] = SessionManifest.Entry(
                    subject: snapshot.subject,
                    mode: snapshot.mode,
                    createdAt: snapshot.createdAt,
                    updatedAt: snapshot.updatedAt,
                    closedAt: snapshot.closedAt,
                    messageCount: snapshot.messages.count,
                    byteSize: SessionManifestStore.fileSize(of: SessionManifestStore.snapshotURL(sessionId: id, projectRoot: projectRoot))
                )
            }
        }
        manifest.order = order
        manifest.archivedIds = archivedIds
        manifest.selectedId = selectedId
        manifestStore.save(manifest, projectRoot: projectRoot)
    }

    private func makeManager() -> SessionManager {
        SessionManager(historyCoordinator: historyCoordinator, projectRoot: projectRoot)
    }

    // MARK: - Boot hydration

    func testBootRestoresOrderSelectionAndTabs() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["older"], subject: "older session", updatedAt: Date(timeIntervalSince1970: 100))
        makeSnapshot(id: "22222222-2222-2222-2222-222222222222", messages: ["recent"], subject: "recent session", updatedAt: Date(timeIntervalSince1970: 300))
        makeSnapshot(id: "33333333-3333-3333-3333-333333333333", messages: ["archived"], subject: "archived session", updatedAt: Date(timeIntervalSince1970: 200), closedAt: Date(timeIntervalSince1970: 250))
        makeManifest(
            order: ["22222222-2222-2222-2222-222222222222", "11111111-1111-1111-1111-111111111111"],
            archivedIds: ["33333333-3333-3333-3333-333333333333"],
            selectedId: "22222222-2222-2222-2222-222222222222"
        )

        let manager = makeManager()

        XCTAssertEqual(manager.conversationTabs.map(\.id), [
            "22222222-2222-2222-2222-222222222222",
            "11111111-1111-1111-1111-111111111111"
        ])
        XCTAssertEqual(manager.conversationTabs.map(\.title), ["recent session", "older session"])
        XCTAssertEqual(manager.selectedId, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(manager.closedConversations.map(\.id), ["33333333-3333-3333-3333-333333333333"])
    }

    func testBootDoesNotDecodeSnapshotsUntilRestore() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["hello"], subject: "s", updatedAt: Date())
        makeManifest(order: ["11111111-1111-1111-1111-111111111111"], selectedId: "11111111-1111-1111-1111-111111111111")

        let manager = makeManager()
        // Lazy load: boot must not materialize message state.
        XCTAssertEqual(manager.conversationTabs.count, 1)

        var input = ""
        var mode: AIMode = .chat
        manager.restoreSession(manager.selectedId, input: &input, mode: &mode)

        XCTAssertEqual(historyCoordinator.committedMessages.count, 1)
        XCTAssertEqual(historyCoordinator.committedMessages.first?.content, "hello")
        XCTAssertEqual(historyCoordinator.conversationEnvelope.subject, "s")
    }

    func testBootWithEmptyProjectCreatesFreshSession() {
        let manager = makeManager()

        XCTAssertEqual(manager.conversationTabs.count, 1)
        XCTAssertFalse(manager.selectedId.isEmpty)
        XCTAssertTrue(manager.closedConversations.isEmpty)
        // The fresh session is persisted so a relaunch keeps the same id.
        XCTAssertTrue(SessionManifestStore.snapshotExists(sessionId: manager.selectedId, projectRoot: projectRoot))
    }

    func testBootPersistsManifestAfterHydration() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["hello"], subject: "s", updatedAt: Date())
        _ = makeManager()

        let manifest = manifestStore.load(projectRoot: projectRoot)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.order, ["11111111-1111-1111-1111-111111111111"])
        XCTAssertEqual(manifest?.selectedId, "11111111-1111-1111-1111-111111111111")
    }

    // MARK: - Registry self-heal

    func testBootHealsBrokenRegistryFromDisk() {
        // No manifest at all — only orphaned snapshots (the regression state:
        // 149 sessions on disk, registry pointing nowhere).
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["oldest"], subject: "old", updatedAt: Date(timeIntervalSince1970: 100))
        makeSnapshot(id: "22222222-2222-2222-2222-222222222222", messages: ["newest"], subject: "new", updatedAt: Date(timeIntervalSince1970: 300))
        makeSnapshot(id: "33333333-3333-3333-3333-333333333333", messages: ["middle"], subject: "mid", updatedAt: Date(timeIntervalSince1970: 200))

        let manager = makeManager()

        // Every on-disk session must be reachable (tab or archive).
        let reachable = Set(manager.conversationTabs.map(\.id)).union(manager.closedConversations.map(\.id))
        XCTAssertEqual(reachable, [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
            "33333333-3333-3333-3333-333333333333"
        ])
        // Most recent becomes active.
        XCTAssertEqual(manager.selectedId, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(manager.conversationTabs.first?.id, "22222222-2222-2222-2222-222222222222")
    }

    func testBootDropsPhantomRegistryEntries() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["real"], subject: "real", updatedAt: Date())
        // Registry references a phantom id that has no snapshot file.
        makeManifest(
            order: ["DEADBEEF-0000-0000-0000-000000000000", "11111111-1111-1111-1111-111111111111"],
            archivedIds: ["DEADBEEF-0000-0000-0000-000000000001"],
            selectedId: "DEADBEEF-0000-0000-0000-000000000000"
        )

        let manager = makeManager()

        XCTAssertFalse(manager.conversationTabs.contains { $0.id.hasPrefix("DEADBEEF") })
        XCTAssertFalse(manager.closedConversations.contains { $0.id.hasPrefix("DEADBEEF") })
        XCTAssertEqual(manager.selectedId, "11111111-1111-1111-1111-111111111111")
        // The heal must have persisted a clean manifest.
        let healed = manifestStore.load(projectRoot: projectRoot)
        XCTAssertEqual(healed?.order, ["11111111-1111-1111-1111-111111111111"])
        XCTAssertNil(healed?.selectedId.flatMap { $0.hasPrefix("DEADBEEF") ? $0 : nil })
    }

    func testBootHealCapsTabsAndArchivesTheRest() {
        let ids = (0..<30).map { String(format: "%02d", $0) + "111111-1111-1111-1111-111111111111" }
        for (index, id) in ids.enumerated() {
            makeSnapshot(id: id, messages: ["m\(index)"], subject: "s\(index)", updatedAt: Date(timeIntervalSince1970: Double(index)))
        }

        let manager = makeManager()

        XCTAssertLessThanOrEqual(manager.conversationTabs.count, 21, "active + 20 heal tabs max")
        XCTAssertEqual(manager.closedConversations.count + manager.conversationTabs.count, 30)
    }

    // MARK: - Empty-overwrite guard

    func testEmptyOverwriteNeverClobbersNonEmptyDiskSnapshot() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["precious", "history"], subject: "keep", updatedAt: Date())
        makeManifest(order: ["11111111-1111-1111-1111-111111111111"], selectedId: "11111111-1111-1111-1111-111111111111")
        let diskURL = SessionManifestStore.snapshotURL(sessionId: "11111111-1111-1111-1111-111111111111", projectRoot: projectRoot)
        let before = try? String(contentsOf: diskURL, encoding: .utf8)

        let manager = makeManager()
        // Simulate the boot-order regression: save with an empty in-memory history.
        manager.saveSnapshot(input: "", mode: .chat)

        let after = try? String(contentsOf: diskURL, encoding: .utf8)
        XCTAssertEqual(after, before, "Empty history must never overwrite a non-empty disk snapshot")
    }

    func testSaveSnapshotPersistsChangesAndManifestMetadata() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["one"], subject: "s", updatedAt: Date())
        makeManifest(order: ["11111111-1111-1111-1111-111111111111"], selectedId: "11111111-1111-1111-1111-111111111111")

        let manager = makeManager()
        var input = ""
        var mode: AIMode = .chat
        manager.restoreSession(manager.selectedId, input: &input, mode: &mode)
        historyCoordinator.appendSync(ChatMessage(role: .assistant, content: "two"))
        historyCoordinator.updateSubject("s")

        manager.saveSnapshot(input: "draft", mode: .coder)

        let entry = manifestStore.load(projectRoot: projectRoot)?.sessions["11111111-1111-1111-1111-111111111111"]
        XCTAssertEqual(entry?.messageCount, 2)
        XCTAssertEqual(entry?.mode, .coder)
        XCTAssertGreaterThan(entry?.byteSize ?? 0, 0)
    }

    // MARK: - Lifecycle: close / recover / discard

    func testCloseArchivesAndRecoverRestoresTab() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["a"], subject: "first", updatedAt: Date())
        makeSnapshot(id: "22222222-2222-2222-2222-222222222222", messages: ["b"], subject: "second", updatedAt: Date())
        makeManifest(order: [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222"
        ], selectedId: "22222222-2222-2222-2222-222222222222")

        let manager = makeManager()
        var input = ""
        var mode: AIMode = .chat

        XCTAssertTrue(manager.close(id: "22222222-2222-2222-2222-222222222222", input: &input, mode: &mode))
        XCTAssertEqual(manager.conversationTabs.map(\.id), ["11111111-1111-1111-1111-111111111111"])
        XCTAssertEqual(manager.closedConversations.map(\.id), ["22222222-2222-2222-2222-222222222222"])
        XCTAssertEqual(manager.selectedId, "11111111-1111-1111-1111-111111111111")
        let closedEntry = manager.closedConversations.first
        XCTAssertNotNil(closedEntry?.closedAt)
        XCTAssertEqual(closedEntry?.messageCount, 1)
        XCTAssertGreaterThan(closedEntry?.byteSize ?? 0, 0)

        XCTAssertTrue(manager.recover(id: "22222222-2222-2222-2222-222222222222", input: &input, mode: &mode))
        XCTAssertTrue(manager.conversationTabs.map(\.id).contains("22222222-2222-2222-2222-222222222222"))
        XCTAssertFalse(manager.closedConversations.contains { $0.id == "22222222-2222-2222-2222-222222222222" })
        XCTAssertEqual(manager.selectedId, "22222222-2222-2222-2222-222222222222")
        // The snapshot file must survive the close/recover round trip.
        XCTAssertTrue(SessionManifestStore.snapshotExists(sessionId: "22222222-2222-2222-2222-222222222222", projectRoot: projectRoot))
    }

    func testCloseRefusesLastTab() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["a"], subject: "only", updatedAt: Date())
        makeManifest(order: ["11111111-1111-1111-1111-111111111111"], selectedId: "11111111-1111-1111-1111-111111111111")

        let manager = makeManager()
        var input = ""
        var mode: AIMode = .chat

        XCTAssertFalse(manager.close(id: "11111111-1111-1111-1111-111111111111", input: &input, mode: &mode))
        XCTAssertEqual(manager.conversationTabs.count, 1)
        XCTAssertTrue(manager.closedConversations.isEmpty)
    }

    func testDiscardClosedDeletesSnapshotAndManifestEntry() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["a"], subject: "first", updatedAt: Date())
        makeSnapshot(id: "22222222-2222-2222-2222-222222222222", messages: ["b"], subject: "second", updatedAt: Date())
        makeManifest(order: [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222"
        ], selectedId: "22222222-2222-2222-2222-222222222222")

        let manager = makeManager()
        var input = ""
        var mode: AIMode = .chat
        _ = manager.close(id: "22222222-2222-2222-2222-222222222222", input: &input, mode: &mode)
        XCTAssertEqual(manager.closedConversations.count, 1)

        manager.discardClosed(id: "22222222-2222-2222-2222-222222222222")

        XCTAssertTrue(manager.closedConversations.isEmpty)
        XCTAssertFalse(SessionManifestStore.snapshotExists(sessionId: "22222222-2222-2222-2222-222222222222", projectRoot: projectRoot))
        let manifest = manifestStore.load(projectRoot: projectRoot)
        XCTAssertNil(manifest?.sessions["22222222-2222-2222-2222-222222222222"])
        XCTAssertFalse(manifest?.archivedIds.contains("22222222-2222-2222-2222-222222222222") ?? false)
    }

    func testStartNewAppendsTabAndSwitches() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["a"], subject: "first", updatedAt: Date())
        makeManifest(order: ["11111111-1111-1111-1111-111111111111"], selectedId: "11111111-1111-1111-1111-111111111111")

        let manager = makeManager()
        var input = ""
        var mode: AIMode = .coder

        let newId = manager.startNew(input: &input, mode: &mode)

        XCTAssertEqual(manager.conversationTabs.count, 2)
        XCTAssertEqual(manager.conversationTabs.last?.id, newId)
        XCTAssertEqual(manager.selectedId, newId)
        XCTAssertEqual(manager.conversationTabs[0].title, "first")
    }

    // MARK: - Project scoping

    func testUpdateProjectRootSwitchesRegistryWithoutLeakage() {
        // Project A
        let projectA = projectRoot!
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["a1"], subject: "A-first", updatedAt: Date())
        makeSnapshot(id: "22222222-2222-2222-2222-222222222222", messages: ["a2"], subject: "A-second", updatedAt: Date())
        makeManifest(order: [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222"
        ], selectedId: "22222222-2222-2222-2222-222222222222")
        let manager = makeManager()
        XCTAssertEqual(manager.conversationTabs.count, 2)

        // Project B — completely separate registry.
        let projectB = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectB) }
        let bID = "44444444-4444-4444-4444-444444444444"
        SessionManager.SessionSnapshot.saveToDisk(
            sessionId: bID,
            snapshot: SessionManager.SessionSnapshot(
                messages: [ChatMessage(role: .user, content: "b1")],
                mode: .coder,
                input: "",
                subject: "B-only",
                createdAt: Date(),
                updatedAt: Date(),
                closedAt: nil
            ),
            projectRoot: projectB
        )

        var input = ""
        var mode: AIMode = .chat
        manager.updateProjectRoot(projectB, input: &input, mode: &mode)

        XCTAssertEqual(manager.conversationTabs.map(\.id), [bID])
        XCTAssertEqual(manager.selectedId, bID)
        XCTAssertFalse(manager.conversationTabs.contains { $0.id.hasPrefix("1111") || $0.id.hasPrefix("2222") })

        // Switching back restores project A's registry untouched.
        manager.updateProjectRoot(projectA, input: &input, mode: &mode)
        XCTAssertEqual(manager.conversationTabs.count, 2)
        XCTAssertEqual(manager.selectedId, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(manager.conversationTabs.map(\.title), ["A-first", "A-second"])
    }

    // MARK: - Legacy UserDefaults migration

    func testLegacyUserDefaultsRegistryMigratesToManifest() {
        makeSnapshot(id: "11111111-1111-1111-1111-111111111111", messages: ["a"], subject: "legacy-open", updatedAt: Date())
        makeSnapshot(id: "22222222-2222-2222-2222-222222222222", messages: ["b"], subject: "legacy-closed", updatedAt: Date(), closedAt: Date())
        let defaults = AppRuntimeEnvironment.userDefaults
        defaults.set(
            try! JSONEncoder().encode(["11111111-1111-1111-1111-111111111111"]),
            forKey: "SessionManager.sessionOrder"
        )
        defaults.set("11111111-1111-1111-1111-111111111111", forKey: "SessionManager.selectedId")
        defaults.set(
            try! JSONEncoder().encode(["22222222-2222-2222-2222-222222222222": ClosedConversation(
                id: "22222222-2222-2222-2222-222222222222",
                title: "legacy-closed",
                closedAt: Date(),
                messageCount: 1
            )]),
            forKey: "SessionManager.closedRegistry"
        )

        let manager = makeManager()

        XCTAssertEqual(manager.conversationTabs.map(\.id), [
            "11111111-1111-1111-1111-111111111111"
        ])
        XCTAssertEqual(manager.selectedId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(manager.closedConversations.map(\.id), ["22222222-2222-2222-2222-222222222222"])
        // Migration must have produced a manifest.
        XCTAssertNotNil(manifestStore.load(projectRoot: projectRoot))
    }
}
