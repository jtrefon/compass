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

        conversationManager.updateProjectRoot(newRoot)
        configureCodebaseIndex(newRoot)

        Task { [loadProjectSession] in
            await loadProjectSession(newRoot)
        }
    }
}
