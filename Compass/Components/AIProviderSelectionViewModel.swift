import Foundation

@MainActor
final class AIProviderSelectionViewModel: ObservableObject {
    @Published var selectedProvider: RemoteAIProvider {
        didSet {
            persistSelection()
        }
    }

    private let selectionStore: AIProviderSelectionStore

    init(selectionStore: AIProviderSelectionStore = AIProviderSelectionStore()) {
        self.selectionStore = selectionStore
        // Store a reference to read from synchronously — the actor's
        // selectedRemoteProvider() is actually a sync method, but
        // actor isolation requires `await`. We use the raw UserDefaults
        // directly to avoid the hard-coded .openRouter default.
        let raw = UserDefaults.standard.string(forKey: "AI.SelectedRemoteProvider")
        self.selectedProvider = raw.flatMap(RemoteAIProvider.init(rawValue:)) ?? .openRouter
    }

    private func persistSelection() {
        let provider = selectedProvider
        Task {
            await selectionStore.setSelectedRemoteProvider(provider)
        }
    }
}
