import Foundation
import Combine

@MainActor
final class StateObservationCoordinator {
    private var cancellables = Set<AnyCancellable>()

    private let fileEditor: FileEditorStateManager
    private let workspace: WorkspaceStateManager
    private let ui: UIStateManager
    private let conversationManager: any ConversationManagerProtocol

    private let onWorkspaceRootChange: (URL) -> Void
    private let onPersistenceRelevantChange: () -> Void

    init(
        fileEditor: FileEditorStateManager,
        workspace: WorkspaceStateManager,
        ui: UIStateManager,
        conversationManager: any ConversationManagerProtocol,
        onWorkspaceRootChange: @escaping (URL) -> Void,
        onPersistenceRelevantChange: @escaping () -> Void
    ) {
        self.fileEditor = fileEditor
        self.workspace = workspace
        self.ui = ui
        self.conversationManager = conversationManager
        self.onWorkspaceRootChange = onWorkspaceRootChange
        self.onPersistenceRelevantChange = onPersistenceRelevantChange
    }

    func startObserving(
        fileTreeExpandedRelativePathsPublisher: Published<Set<String>>.Publisher,
        showHiddenFilesInFileTreePublisher: Published<Bool>.Publisher
    ) {
        workspace.$currentDirectory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newDir in
                guard let newDir else { return }
                self?.onWorkspaceRootChange(newDir)
            }
            .store(in: &cancellables)

        ui.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onPersistenceRelevantChange()
            }
            .store(in: &cancellables)

        conversationManager.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onPersistenceRelevantChange()
            }
            .store(in: &cancellables)

        fileTreeExpandedRelativePathsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onPersistenceRelevantChange()
            }
            .store(in: &cancellables)

        showHiddenFilesInFileTreePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onPersistenceRelevantChange()
            }
            .store(in: &cancellables)
    }
}
