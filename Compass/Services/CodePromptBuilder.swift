import Foundation

extension AIService {
    func explainCode(_ code: String) async throws -> String {
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: "Explain the following code in clear, concise terms:\n\n\(code)",
            context: nil, tools: nil, mode: nil, projectRoot: nil
        ))
        return response.content ?? ""
    }

    func refactorCode(_ code: String, instructions: String) async throws -> String {
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: "Refactor this code using the following instructions:\n\(instructions)\n\nCode:\n\(code)",
            context: nil, tools: nil, mode: nil, projectRoot: nil
        ))
        return response.content ?? ""
    }

    func generateCode(_ prompt: String) async throws -> String {
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: "Generate code for the following request:\n\(prompt)",
            context: nil, tools: nil, mode: nil, projectRoot: nil
        ))
        return response.content ?? ""
    }

    func fixCode(_ code: String, error: String) async throws -> String {
        let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
            message: "Fix this code. Error message:\n\(error)\n\nCode:\n\(code)",
            context: nil, tools: nil, mode: nil, projectRoot: nil
        ))
        return response.content ?? ""
    }
}
