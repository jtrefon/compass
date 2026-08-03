import Foundation

enum OpenRouterServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(Int, body: String?)
    case missingAPIKey
    case emptyModel
    case streamTimeout(StreamLivenessError)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The OpenRouter URL is invalid."
        case .invalidResponse:
            return "OpenRouter returned an unexpected response."
        case .serverError(let code, let body):
            if let body, !body.isEmpty {
                return "OpenRouter request failed (HTTP \(code)): \(body)"
            }
            return "OpenRouter request failed (HTTP \(code))."
        case .missingAPIKey:
            return "An API key is required."
        case .emptyModel:
            return "Select a model before testing."
        case .streamTimeout(let kind):
            switch kind {
            case .idle:
                return "OpenRouter stream timed out (idle): no data was received within the idle deadline."
            case .absolute:
                return "OpenRouter stream timed out (absolute): the stream exceeded the maximum allowed duration."
            }
        }
    }
}
