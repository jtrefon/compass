import Foundation

extension AIService {
    func sendMessageResult(
        _ message: String,
        context: String?,
        tools: [AITool]?,
        mode: AIMode?
    ) async -> Result<AIServiceResponse, AppError> {
        do {
            let response = try await sendMessage(AIServiceMessageWithProjectRootRequest(
                message: message,
                context: context,
                tools: tools,
                mode: mode,
                projectRoot: nil
            ))
            return .success(response)
        } catch {
            return .failure(Self.mapToAppError(error, operation: "sendMessage"))
        }
    }

    func sendMessageResult(
        _ request: AIServiceMessageWithProjectRootRequest
    ) async -> Result<AIServiceResponse, AppError> {
        do {
            let response = try await sendMessage(request)
            return .success(response)
        } catch {
            return .failure(Self.mapToAppError(error, operation: "sendMessageWithProjectRoot"))
        }
    }

    func sendMessageResult(
        _ request: AIServiceHistoryRequest
    ) async -> Result<AIServiceResponse, AppError> {
        do {
            let response = try await sendMessage(request)
            return .success(response)
        } catch {
            return .failure(Self.mapToAppError(error, operation: "sendMessageHistory"))
        }
    }

    private static func mapToAppError(_ error: Error, operation: String) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .aiServiceError("AIService.\(operation) failed: \(error.localizedDescription)")
    }
}
