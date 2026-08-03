import Foundation

actor ModelRoutingAIService: AIService, RemoteAIAccountStatusRefreshing {
    private let registry: AIServiceRegistry

    /// Delegates to the active service's cache policy. Because `preservesCache`
    /// is nonisolated and the underlying service is resolved asynchronously, this
    /// may return a stale value briefly during provider switches — safe because
    /// messages in flight are already consistent with the previous service.
    nonisolated var preservesCache: Bool {
        false
    }

    init(registry: AIServiceRegistry) {
        self.registry = registry
    }

    private func selectedRemoteService() async -> (any AIService)? {
        await registry.activeRemoteService()
    }

    private func selectedService() async -> (any AIService)? {
        await registry.activeService()
    }

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse {
        guard let service = await selectedService() else {
            throw AppError.aiServiceError("No AI service available.")
        }
        return try await service.sendMessage(request)
    }

    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse {
        guard let service = await selectedService() else {
            throw AppError.aiServiceError("No AI service available.")
        }
        return try await service.sendMessage(request)
    }

    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse {
        guard let service = await selectedService() else {
            throw AppError.aiServiceError("No AI service available.")
        }
        return try await service.sendMessageStreaming(request, runId: runId)
    }

    func explainCode(_ code: String) async throws -> String {
        guard let service = await selectedService() else {
            throw AppError.aiServiceError("No AI service available.")
        }
        return try await service.explainCode(code)
    }

    func refactorCode(_ code: String, instructions: String) async throws -> String {
        guard let service = await selectedService() else {
            throw AppError.aiServiceError("No AI service available.")
        }
        return try await service.refactorCode(code, instructions: instructions)
    }

    func generateCode(_ prompt: String) async throws -> String {
        guard let service = await selectedService() else {
            throw AppError.aiServiceError("No AI service available.")
        }
        return try await service.generateCode(prompt)
    }

    func fixCode(_ code: String, error: String) async throws -> String {
        guard let service = await selectedService() else {
            throw AppError.aiServiceError("No AI service available.")
        }
        return try await service.fixCode(code, error: error)
    }

    func refreshAccountBalance(runId: String?) async {
        guard let remoteService = await selectedRemoteService() else { return }
        await (remoteService as? RemoteAIAccountStatusRefreshing)?.refreshAccountBalance(runId: runId)
    }
}
