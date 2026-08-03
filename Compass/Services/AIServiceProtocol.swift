import Foundation

public protocol AIService: Sendable {
    /// When true, the service requests that downstream layers skip all message
    /// mutations (deduplication, truncation, reasoning stripping, reordering).
    /// This preserves byte-identical message prefixes across consecutive requests,
    /// enabling KV-cache reuse on local inference servers (llama.cpp, MLX, etc.).
    var preservesCache: Bool { get }

    func sendMessage(_ request: AIServiceMessageWithProjectRootRequest) async throws -> AIServiceResponse
    func sendMessage(_ request: AIServiceHistoryRequest) async throws -> AIServiceResponse
    func sendMessageStreaming(_ request: AIServiceHistoryRequest, runId: String) async throws -> AIServiceResponse
}

public protocol RemoteAIAccountStatusRefreshing: Sendable {
    func refreshAccountBalance(runId: String?) async
}
