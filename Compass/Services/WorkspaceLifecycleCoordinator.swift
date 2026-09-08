import Foundation

@MainActor
final class WorkspaceLifecycleCoordinator {
    private let conversationManager: any ConversationManagerProtocol
    private let configureCodebaseIndex: (URL) -> Void
    private let loadProjectSession: (URL) async -> Void

    init(
        conversationManager: any ConversationManagerProtocol,
        configureCodebaseIndex: @escaping (URL) -> Void,
        loadProjectSession: @escaping (URL) async -> Void
    ) {
        self.conversationManager = conversationManager
        self.configureCodebaseIndex = configureCodebaseIndex
        self.loadProjectSession = loadProjectSession
    }

    func workspaceRootDidChange(to newRoot: URL) {
        ProjectRootRegistry.shared.set(newRoot)

        // Test hosts (unit/harness/UI) restore the user's last workspace into
        // `WorkspaceStateManager.currentDirectory` at startup. Rebinding the
        // conversation manager here would hydrate — and heal-write — the user's
        // REAL project session registry during test runs. Production launches
        // (.app mode) are unaffected; test hosts bootstrap their own roots via
        // updateProjectRoot/configureProject.
        guard !AppRuntimeEnvironment.launchContext.isTesting else { return }

        conversationManager.updateProjectRoot(newRoot)
        configureCodebaseIndex(newRoot)

        Task { [loadProjectSession] in
            await loadProjectSession(newRoot)
        }
    }
}
