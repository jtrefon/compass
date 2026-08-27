import Foundation

/// Single vocabulary for transport-level failures driving retry policy.
///
/// **Design rationale:**
/// - Classification is TIERED: typed sources (cancellation, HTTP status from
///   `OpenRouterServiceError`, `URLError` codes) are consulted before any
///   string heuristics. Provider wording drift can no longer silently
///   misclassify retries — strings are a demoted last-resort fallback, and
///   every fallback hit is trace-tagged so new shapes get typed over time.
/// - One classifier, one vocabulary: `AIInteractionCoordinator`'s retry
///   policy, banners, and backoff all switch on `TransportFailure` instead of
///   three independent string-sniffing predicates.
enum TransportFailure: Equatable {
    case cancellation
    /// 402 / out of credits — not retryable; user must see why.
    case paymentRequired(status: Int?)
    /// 429 — stage-capped exponential backoff.
    case rateLimit(status: Int?)
    /// Transient connectivity problem — long escalating schedule + banner.
    case network(code: Int?)
    /// Non-transient HTTP failure (e.g. 4xx/5xx other than 402/429).
    case server(status: Int?)
    case unclassified(String)
}

enum TransportFailureClassifier {
    static func classify(_ error: Error) -> TransportFailure {
        // Tier 1: cancellation is checked first — retrying a cancelled task
        // is always wrong.
        if error is CancellationError { return .cancellation }

        // Tier 2: typed provider status codes (the actual source of truth).
        if let serviceError = error as? OpenRouterServiceError {
            switch serviceError {
            case .serverError(let status, _):
                switch status {
                case 402: return .paymentRequired(status: status)
                case 429: return .rateLimit(status: status)
                default: return .server(status: status)
                }
            case .streamTimeout:
                return .network(code: nil)
            default:
                break
            }
        }

        // Tier 3: typed URL error codes.
        if let urlError = error as? URLError {
            return classifyURLError(urlError.errorCode)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return classifyURLError(nsError.code)
        }

        // Tier 4: structured app-level wrapping.
        if let appErr = error as? AppError {
            switch appErr {
            case .networkError:
                return .network(code: nil)
            case .aiServiceError(let message):
                let classified = Self.classifyDescription(message)
                // Trace unmapped aiServiceError shapes so they surface for typing.
                if case .unclassified = classified {
                    Task {
                        await AIToolTraceLogger.shared.log(type: "classifier.string_fallback", data: [
                            "shape": "AppError.aiServiceError"
                        ])
                    }
                }
                return classified
            default:
                break
            }
        }

        // Tier 5: legacy phrase heuristics on the raw description.
        let description = String(describing: error)
        return Self.classifyDescription(description)
    }

    private static func classifyURLError(_ code: Int) -> TransportFailure {
        if Self.isTransientNetworkURLError(code) { return .network(code: code) }
        return .server(status: nil)
    }

    /// Phrase-based classification — LAST resort only.
    static func classifyDescription(_ text: String) -> TransportFailure {
        let lowered = text.lowercased()
        if lowered.contains("429") || lowered.contains("rate-limit") || lowered.contains("rate_limit") {
            return .rateLimit(status: nil)
        }
        if lowered.contains("402") || lowered.contains("insufficient balance") || lowered.contains("more credits") {
            return .paymentRequired(status: nil)
        }
        if Self.networkPhraseSet.contains(where: { lowered.contains($0) }) {
            return .network(code: nil)
        }
        return .unclassified(text)
    }

    // MARK: - Network phrase/code tables (moved here as single source)

    static let networkPhraseSet: Set<String> = [
        "offline", "internet connection appears to be offline", "network connection was lost",
        "timed out", "could not connect", "cannot connect to", "network is unreachable",
        "connection reset", "connection dropped", "no network connection", "nsurlerror",
        "the network connection was lost", "request timed out", "connection failed",
    ]

    static func isTransientNetworkURLError(_ code: Int) -> Bool {
        let urlErrorCode = URLError.Code(rawValue: code)
        switch urlErrorCode {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable, .dataNotAllowed, .internationalRoamingOff,
             .callIsActive, .secureConnectionFailed, .clientCertificateRejected,
             .clientCertificateRequired, .cannotLoadFromNetwork,
             .backgroundSessionWasDisconnected, .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return false
        }
    }
}
