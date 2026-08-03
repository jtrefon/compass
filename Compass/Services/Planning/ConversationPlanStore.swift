import Foundation

protocol ConversationPlanStoring: Actor {
    func get(conversationId: String) -> String?
    func set(conversationId: String, plan: String)
    func getPlan(conversationId: String) -> TaskPlan?
    func setPlan(conversationId: String, plan: TaskPlan)
    func reset()
}

actor ConversationPlanStore {
    static let shared = ConversationPlanStore()

    private var projectRoot: URL?
    private var cache: [String: String] = [:]
    private var structCache: [String: TaskPlan] = [:]
    private var accessOrder: [String] = []
    private let maxCachedPlans = 5

    func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }

    // MARK: - Legacy string-based API (deprecated)

    @available(*, deprecated, message: "Use getPlan(conversationId:) with structured TaskPlan instead.")
    func get(conversationId: String) -> String? {
        if let cached = cache[conversationId] {
            touchAccessOrder(conversationId)
            return cached
        }
        guard let url = planFileURL(conversationId: conversationId, ext: "md"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        storeCacheEntry(conversationId: conversationId, plan: text)
        return text
    }

    @available(*, deprecated, message: "Use setPlan(conversationId:plan:) with structured TaskPlan instead.")
    func set(conversationId: String, plan: String) {
        storeCacheEntry(conversationId: conversationId, plan: plan)
        guard let url = planFileURL(conversationId: conversationId, ext: "md") else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plan.data(using: .utf8)?.write(to: url, options: [.atomic])
        } catch {
        }
    }

    // MARK: - Structured TaskPlan API

    func getPlan(conversationId: String) -> TaskPlan? {
        if let cached = structCache[conversationId] {
            touchAccessOrder(conversationId)
            return cached
        }
        guard let url = planFileURL(conversationId: conversationId, ext: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            let plan = try JSONDecoder().decode(TaskPlan.self, from: data)
            structCache[conversationId] = plan
            touchAccessOrder(conversationId)
            return plan
        } catch {
            return nil
        }
    }

    func setPlan(conversationId: String, plan: TaskPlan) {
        structCache[conversationId] = plan
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

    // MARK: - Private

    private func storeCacheEntry(conversationId: String, plan: String) {
        cache[conversationId] = plan
        touchAccessOrder(conversationId)
        evictIfNeeded()
    }

    private func touchAccessOrder(_ conversationId: String) {
        accessOrder.removeAll { $0 == conversationId }
        accessOrder.append(conversationId)
    }

    private func evictIfNeeded() {
        while cache.count + structCache.count > maxCachedPlans, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            structCache.removeValue(forKey: oldest)
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
        structCache.removeAll()
        accessOrder.removeAll()
        projectRoot = nil
    }
}

extension ConversationPlanStore: ConversationPlanStoring {}
