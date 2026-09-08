import Foundation

actor ConversationPlanStore {
    static let shared = ConversationPlanStore()

    private var projectRoot: URL?
    private var cache: [String: TaskPlan] = [:]
    private var accessOrder: [String] = []
    private let maxCachedPlans = 5

    func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }

    func getPlan(conversationId: String) -> TaskPlan? {
        if let cached = cache[conversationId] {
            touchAccessOrder(conversationId)
            return cached
        }
        guard let url = planFileURL(conversationId: conversationId, ext: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            let plan = try JSONDecoder().decode(TaskPlan.self, from: data)
            cache[conversationId] = plan
            touchAccessOrder(conversationId)
            return plan
        } catch {
            return nil
        }
    }

    func setPlan(conversationId: String, plan: TaskPlan) {
        cache[conversationId] = plan
        touchAccessOrder(conversationId)
        evictIfNeeded()
        guard let url = planFileURL(conversationId: conversationId, ext: "json") else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(plan)
            try data.write(to: url, options: [.atomic])
        } catch {
        }
    }

    private func touchAccessOrder(_ conversationId: String) {
        accessOrder.removeAll { $0 == conversationId }
        accessOrder.append(conversationId)
    }

    private func evictIfNeeded() {
        while cache.count > maxCachedPlans, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }

    private func planFileURL(conversationId: String, ext: String) -> URL? {
        guard let projectRoot else { return nil }
        return projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent("\(conversationId).\(ext)")
    }

    func reset() {
        cache.removeAll()
        accessOrder.removeAll()
        projectRoot = nil
    }
}