import Foundation

struct OrchestrationRunSnapshot: Codable {
    struct ToolCallSummary: Codable {
        let id: String
        let name: String
        let argumentKeys: [String]
    }

    struct ToolResultSummary: Codable {
        let toolCallId: String
        let toolName: String
        let status: String
        let targetFile: String?
        let outputPreview: String
    }

    let runId: String
    let conversationId: String
    let phase: String
    let iteration: Int?
    let timestamp: Date
    let userInput: String
    let assistantDraft: String?
    let failureReason: String?
    let toolCalls: [ToolCallSummary]
    let toolResults: [ToolResultSummary]
    let planSummary: String?
}
