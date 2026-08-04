//
//  OpenRouterSettingsViewModel.swift
//  Compass
//
//  Created by AI Assistant on 20/12/2025.
//

import SwiftUI

@MainActor
final class OpenRouterSettingsViewModel: ObservableObject {
    enum StatusKind {
        case idle
        case loading
        case success
        case warning
        case error
    }

    struct Status: Equatable {
        let kind: StatusKind
        let message: String
    }

    @Published var apiKey: String {
        didSet { persist() }
    }
    @Published var baseURL: String {
        didSet { persist() }
    }
    @Published var modelQuery: String {
        didSet {
            updateModelQuery()
            persist()
        }
    }
    @Published var selectedModel: String {
        didSet { persist() }
    }
    @Published var systemPrompt: String {
        didSet { persist() }
    }
    @Published var reasoningMode: ReasoningMode {
        didSet { persist() }
    }
    @Published var toolPromptMode: ToolPromptMode {
        didSet { persist() }
    }
    @Published var contextOverride: Int {
        didSet { persist() }
    }

    @Published private(set) var models: [OpenRouterModel] = []
    @Published private(set) var filteredModels: [OpenRouterModel] = []
    @Published private(set) var modelStatus = Status(kind: .idle, message: "Models not loaded yet.")
    @Published private(set) var keyStatus = Status(kind: .idle, message: "Key not validated.")
    @Published private(set) var testStatus = Status(kind: .idle, message: "No test run.")
    @Published private(set) var modelValidationStatus = Status(kind: .idle, message: "Model not validated.")

    private let store: any OpenRouterSettingsStoring
    private let client: OpenRouterAPIClient
    private let providerDisplayName: String
    private let appName = "OSX IDE"
    private let referer = ""
    private var hasLoadedModels = false

    private func requestContext() -> OpenRouterAPIClient.RequestContext {
        OpenRouterAPIClient.RequestContext(
            baseURL: baseURL,
            appName: appName,
            referer: referer
        )
    }

    init(
        store: any OpenRouterSettingsStoring = OpenRouterSettingsStore(),
        client: OpenRouterAPIClient = OpenRouterAPIClient(),
        providerDisplayName: String = "OpenRouter"
    ) {
        let settings = store.load(includeApiKey: false)
        self.store = store
        self.client = client
        self.providerDisplayName = providerDisplayName
        self.apiKey = settings.apiKey
        self.baseURL = settings.baseURL
        self.selectedModel = settings.model
        self.modelQuery = settings.model
        self.systemPrompt = settings.systemPrompt
        self.reasoningMode = settings.reasoningMode
        self.toolPromptMode = settings.toolPromptMode
        self.contextOverride = settings.contextOverride
    }

    func loadApiKeyIfAvailable() {
        let settings = store.load(includeApiKey: true)
        if settings.apiKey != apiKey {
            apiKey = settings.apiKey
        }
    }

    func loadModels(force: Bool = false) async {
        if hasLoadedModels && !force { return }
        modelStatus = Status(kind: .loading, message: "Loading models...")
        do {
            let models = try await client.fetchModels(
                apiKey: apiKey.isEmpty ? nil : apiKey,
                context: requestContext()
            )
            let sorted = models.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            self.models = sorted
            hasLoadedModels = true
            updateModelQuery()
            modelStatus = Status(kind: .success, message: "\(sorted.count) models available.")
        } catch {
            modelStatus = Status(kind: .error, message: error.localizedDescription)
        }
    }

    func validateKey(isCustomEndpoint: Bool = false) async {
        if isCustomEndpoint {
            guard !baseURL.isEmpty else {
                keyStatus = Status(kind: .warning, message: "Enter the server URL first.")
                return
            }
            keyStatus = Status(kind: .loading, message: "Testing connection...")
            do {
                let models = try await client.fetchModels(
                    apiKey: nil,
                    context: requestContext()
                )
                let sorted = models.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                self.models = sorted
                hasLoadedModels = true
                updateModelQuery()
                if let first = sorted.first {
                    var contextLabel = "unknown"
                    // Auto-populate context override from detected model
                    if self.contextOverride <= 0 {
                        if let detected = first.contextLength, detected > 0 {
                            self.contextOverride = detected
                            contextLabel = "\(detected)"
                        } else {
                            // Fall back to model profile lookup for servers that don't
                            // report context_length (llama.cpp, etc.)
                            let profile = ModelContextProfile.profile(for: first.id)
                            if profile.windowSize > 0 {
                                self.contextOverride = profile.windowSize
                                contextLabel = "\(profile.windowSize) (profile)"
                            }
                        }
                    } else {
                        contextLabel = "\(self.contextOverride)"
                    }
                    keyStatus = Status(kind: .success, message: "\(first.displayName) (\(contextLabel) ctx)")
                } else {
                    keyStatus = Status(kind: .success, message: "Server reachable (no models reported).")
                }
            } catch {
                keyStatus = Status(kind: .error, message: error.localizedDescription)
            }
            return
        }
        guard !apiKey.isEmpty else {
            keyStatus = Status(kind: .warning, message: "Add an API key to validate.")
            return
        }
        keyStatus = Status(kind: .loading, message: "Validating key...")
        do {
            try await client.validateKey(
                apiKey: apiKey,
                context: requestContext()
            )
            keyStatus = Status(kind: .success, message: "Key is valid.")
        } catch {
            keyStatus = Status(kind: .error, message: error.localizedDescription)
        }
    }

    func validateModel() async {
        let activeModel = activeModelId()
        guard !activeModel.isEmpty else {
            modelValidationStatus = Status(kind: .warning, message: "Select a model to validate.")
            return
        }
        modelValidationStatus = Status(kind: .loading, message: "Validating model...")
        if models.isEmpty {
            await loadModels(force: true)
        }
        if models.contains(where: { $0.id == activeModel }) {
            modelValidationStatus = Status(kind: .success, message: "Model found in \(providerDisplayName) list.")
        } else {
            modelValidationStatus = Status(kind: .error, message: "Model not found. Check spelling.")
        }
    }

    func testModel(isCustomEndpoint: Bool = false) async {
        if !isCustomEndpoint {
            guard !apiKey.isEmpty else {
                testStatus = Status(kind: .warning, message: "Add an API key to run a test.")
                return
            }
        }
        let activeModel = activeModelId()
        guard !activeModel.isEmpty else {
            testStatus = Status(kind: .warning, message: "Select a model before testing.")
            return
        }
        testStatus = Status(kind: .loading, message: "Testing model latency...")
        do {
            let effectiveKey = isCustomEndpoint ? (apiKey.isEmpty ? "" : apiKey) : apiKey
            let latency = try await client.testModel(
                apiKey: effectiveKey,
                model: activeModel,
                context: requestContext()
            )
            let ms = Int(latency * 1000)
            testStatus = Status(kind: .success, message: "Response in \(ms) ms.")
        } catch {
            testStatus = Status(kind: .error, message: error.localizedDescription)
        }
    }

    func commitModelEntry() {
        selectedModel = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func selectModel(_ model: OpenRouterModel) {
        modelQuery = model.id
        selectedModel = model.id
        modelValidationStatus = Status(kind: .idle, message: "Model selected.")
    }

    func shouldShowSuggestions() -> Bool {
        // Suggestions also render with an empty query: providers like custom
        // endpoints expose bare model ids that never match the OpenRouter
        // popular list, so the opened picker must show the provider's catalog
        // immediately (mirrors the chat-panel picker's fallback).
        !filteredModels.isEmpty
    }

    private func updateModelQuery() {
        let trimmed = modelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            filteredModels = Array(models.prefix(60))
        } else {
            filteredModels = models.filter {
                $0.displayName.localizedCaseInsensitiveContains(trimmed) ||
                    $0.id.localizedCaseInsensitiveContains(trimmed)
            }
            filteredModels = Array(filteredModels.prefix(60))
        }
    }

    private func persist() {
        let activeModel = activeModelId()
        let settings = OpenRouterSettings(
            apiKey: apiKey,
            model: activeModel,
            baseURL: baseURL,
            systemPrompt: systemPrompt,
            reasoningMode: reasoningMode,
            toolPromptMode: toolPromptMode,
            contextOverride: contextOverride
        )
        store.save(settings)
    }

    private func activeModelId() -> String {
        let candidate = selectedModel.isEmpty ? modelQuery : selectedModel
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
