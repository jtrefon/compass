import Foundation
import Combine

extension CodebaseIndex {
    public convenience init(eventBus: EventBusProtocol) throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        try self.init(eventBus: eventBus, projectRoot: root, aiService: OpenRouterAIService(eventBus: eventBus))
    }

    public func start() {
        Task {
            try? await ensureReady()
            await coordinator.start(projectRoot: projectRoot)
        }
        Task {
            await pruneOutOfScopeResourcesIfNeeded()
        }
    }

    public func stop() {
        isEnabled = false
        coordinatorStartTask?.cancel()
        coordinatorStartTask = nil
        Task {
            try? await ensureReady()
            await coordinator.stop()
        }
        Task {
            await database.shutdown()
        }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        Task {
            try? await ensureReady()
            await coordinator.setEnabled(enabled)
        }
    }

    public func reindexProject() {
        guard isEnabled else { return }
        Task {
            try? await ensureReady()
            await pruneOutOfScopeResourcesIfNeeded()
            await coordinator.reindexProject(rootURL: projectRoot)
        }
    }

    private func pruneOutOfScopeResourcesIfNeeded() async {
        do {
            let removed = try await database.pruneResourcesOutside(projectRoot: projectRoot)
            if removed > 0 {
                await IndexLogger.shared.log("Pruned \(removed) out-of-scope resources from index database")
            }
        } catch {
            await IndexLogger.shared.log("Failed to prune out-of-scope resources: \(error)")
        }
    }
}
