import Foundation

extension AIService {
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
}

private extension AIService {
    static func mapToAppError(_ error: Error, operation: String) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .aiServiceError("AIService.\(operation) failed: \(error.localizedDescription)")
    }
}
