import SwiftUI
import Combine

@MainActor
final class ModelSearchViewModel: ObservableObject {
    @Published var searchQuery: String = ""
    @Published var allModels: [OpenRouterModel] = []
    @Published private(set) var recentModelIds: [String] = []

    private let apiClient = OpenRouterAPIClient()
    private let recentKey = "recentModelIds"

    static let popularModelIds: [String] = [
        "openai/gpt-4o",
        "openai/gpt-4o-mini",
        "anthropic/claude-3.5-sonnet",
        "google/gemini-2.0-flash-001",
        "deepseek/deepseek-chat",
        "meta-llama/llama-3.3-70b-instruct",
        "mistralai/mistral-large-2407",
        "qwen/qwen-2.5-72b-instruct",
        "anthropic/claude-3-haiku",
        "cohere/command-r-plus-08-2024"
    ]

    var displayModels: [OpenRouterModel] {
        if searchQuery.isEmpty {
            return topModels
        }
        let q = searchQuery.lowercased()
        return allModels.filter { model in
            model.id.lowercased().contains(q) ||
            (model.name?.lowercased().contains(q) ?? false)
        }
    }

    private var topModels: [OpenRouterModel] {
        var seen = Set<String>()
        var result: [OpenRouterModel] = []

        for id in recentModelIds {
            guard seen.insert(id).inserted else { continue }
            if let model = allModels.first(where: { $0.id == id }) {
                result.append(model)
            }
        }

        for id in Self.popularModelIds {
            guard seen.insert(id).inserted else { continue }
            if result.count >= 10 { break }
            if let model = allModels.first(where: { $0.id == id }) {
                result.append(model)
            }
        }

        // Custom endpoints (and any provider whose catalog uses bare ids like
        // "gpt-4o" / "llama3") never match the OpenRouter-qualified popular
        // set — the opened list was empty until the user typed. Fall back to
        // the provider's own catalog so the picker always shows models.
        for model in allModels {
            if result.count >= 30 { break }
            if seen.insert(model.id).inserted {
                result.append(model)
            }
        }

        return result
    }

    init() {
        loadRecentIds()
    }

    func loadModels(baseURL: String = "https://openrouter.ai/api/v1") async {
        do {
            let context = OpenRouterAPIClient.RequestContext(
                baseURL: baseURL,
                appName: "Compass",
                referer: ""
            )
            let models = try await apiClient.fetchModels(apiKey: Optional<String>.none, context: context)
            allModels = models
            for model in models where model.contextLength != nil {
                ModelContextRegistry.shared.setContextLength(model.contextLength!, for: model.id)
            }
        } catch {
            // An empty picker with no explanation looks like a dead feature —
            // log the failure so model-catalog problems (ATS/Local Network
            // denials, unreachable servers) are diagnosable.
            Task {
                await AppLogger.shared.error(
                    category: .ai,
                    message: "model_catalog.fetch_failed",
                    context: AppLogger.LogCallContext(metadata: [
                        "baseURL": baseURL,
                        "error": error.localizedDescription
                    ])
                )
            }
        }
    }

    func recordSelection(_ modelId: String) {
        recentModelIds.removeAll { $0 == modelId }
        recentModelIds.insert(modelId, at: 0)
        if recentModelIds.count > 5 {
            recentModelIds = Array(recentModelIds.prefix(5))
        }
        saveRecentIds()
    }

    private func loadRecentIds() {
        recentModelIds = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    private func saveRecentIds() {
        UserDefaults.standard.set(recentModelIds, forKey: recentKey)
    }
}
