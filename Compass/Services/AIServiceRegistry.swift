import Foundation

/// Registry of AI services per provider.
///
/// **Sendable safety:** `@unchecked Sendable` is justified here because the
/// `services` dictionary is mutated ONLY during single-threaded setup
/// (DependencyContainer.init / test factories) before any concurrent access
/// occurs. After setup, all access is read-only (`service(for:)`,
/// `allServices()`). The `providerSelectionStore` and `localSelectionStore`
/// are themselves Sendable. A lock guards the rare concurrent read path as a
/// defensive measure, but in practice reads happen after configuration completes.
final class AIServiceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [AIProviderID: any AIService] = [:]
    private let providerSelectionStore: AIProviderSelectionStore
    private let localSelectionStore: LocalModelSelectionStore

    init(
        providerSelectionStore: AIProviderSelectionStore = AIProviderSelectionStore(),
        localSelectionStore: LocalModelSelectionStore = LocalModelSelectionStore()
    ) {
        self.providerSelectionStore = providerSelectionStore
        self.localSelectionStore = localSelectionStore
    }

    func register(provider: AIProviderID, service: any AIService) {
        lock.withLock { services[provider] = service }
    }

    func service(for provider: AIProviderID) -> (any AIService)? {
        lock.withLock { services[provider] }
    }

    func allServices() -> [AIProviderID: any AIService] {
        lock.withLock { services }
    }

    func activeRemoteService() async -> (any AIService)? {
        let selected = await providerSelectionStore.selectedRemoteProvider()
        return lock.withLock { services[selected.toAIProviderID] }
    }

    func activeService() async -> (any AIService)? {
        let isOffline = await localSelectionStore.isOfflineModeEnabled()
        if isOffline {
            return lock.withLock { services[.local] }
        }
        return await activeRemoteService()
    }
}
