import Foundation

@MainActor
final class AIInteractionCoordinator {
    struct SendMessageWithRetryRequest {
        let messages: [ChatMessage]
        let mediaAttachments: [ChatMessageMediaAttachment]
        let tools: [AITool]
        let mode: AIMode
        let projectRoot: URL
        let runId: String?
        let stage: AIRequestStage?
        let conversationId: String?
        let usesLocalModel: Bool
        let providerName: String?
        let preservesCache: Bool

        init(
            messages: [ChatMessage],
            mediaAttachments: [ChatMessageMediaAttachment] = [],
            tools: [AITool],
            mode: AIMode,
            projectRoot: URL,
            runId: String? = nil,
            stage: AIRequestStage? = nil,
            conversationId: String? = nil,
            usesLocalModel: Bool = false,
            providerName: String? = nil,
            preservesCache: Bool = false
        ) {
            self.messages = messages
            self.mediaAttachments = mediaAttachments
            self.tools = tools
            self.mode = mode
            self.projectRoot = projectRoot
            self.runId = runId
            self.stage = stage
            self.conversationId = conversationId
            self.usesLocalModel = usesLocalModel
            self.providerName = providerName
            self.preservesCache = preservesCache
        }
    }

    private var aiService: AIService
    private var codebaseIndex: CodebaseIndexProtocol?
    private var vectorStoreService: VectorStoreService?
    private var embedder: (any MemoryEmbeddingGenerating)?
    private let conversationPolicy: ConversationPolicyProtocol
    private let settingsStore: any OpenRouterSettingsLoading
    private let eventBus: any EventBusProtocol

    init(
        aiService: AIService,
        codebaseIndex: CodebaseIndexProtocol?,
        vectorStoreService: VectorStoreService? = nil,
        embedder: (any MemoryEmbeddingGenerating)? = nil,
        conversationPolicy: ConversationPolicyProtocol = ConversationPolicy(),
        settingsStore: any OpenRouterSettingsLoading = OpenRouterSettingsStore(),
        eventBus: any EventBusProtocol
    ) {
        self.aiService = aiService
        self.codebaseIndex = codebaseIndex
        self.vectorStoreService = vectorStoreService
        self.embedder = embedder
        self.conversationPolicy = conversationPolicy
        self.settingsStore = settingsStore
        self.eventBus = eventBus
    }

    func updateAIService(_ newService: AIService) {
        aiService = newService
    }

    func updateCodebaseIndex(_ newIndex: CodebaseIndexProtocol?) {
        codebaseIndex = newIndex
    }

    func updateVectorStoreService(_ service: VectorStoreService?) {
        vectorStoreService = service
    }

    func updateEmbedder(_ embedder: (any MemoryEmbeddingGenerating)?) {
        self.embedder = embedder
    }

    func sendMessageWithRetry(
        _ request: SendMessageWithRetryRequest
    ) async -> Result<AIServiceResponse, AppError> {
        let isUnitTestRun = isRunningUnitTests()
        let modelID = settingsStore.load(includeApiKey: false).model
        let sanitizedMessages = await PipelineProcessor.prepareForRequest(
            messages: request.messages,
            modelID: modelID,
            preservesCache: request.preservesCache,
            runId: request.runId,
            stage: request.stage
        )
        let filteredTools = conversationPolicy.allowedTools(
            for: request.stage,
            mode: request.mode,
            from: request.tools
        )
        let maxAttempts = maxAttemptsForRequestStage(
            request.stage,
            isRunningUnitTests: isUnitTestRun
        )
        var lastError: AppError?
        let providerLabel = request.providerName ?? "OpenRouter"
        let retryStart = Date()
        var networkIssueActive = false

        let loopMax = maxAttempts

        enum RetryDecision {
            case retry
            case giveUp
            case degrade
        }

        func handleRetry(_ error: Error, attempt: Int) async -> RetryDecision {
            let action = await classifyRetry(
                error,
                attempt: attempt,
                maxAttempts: maxAttempts,
                retryStart: retryStart,
                stage: request.stage,
                providerName: providerLabel,
                isUnitTestRun: isUnitTestRun
            )
            switch action {
            case .cancel:
                lastError = .aiServiceError("Request cancelled")
                return .giveUp
            case .insufficientBalance:
                lastError = Self.mapToAppError(error, operation: "sendMessageStreaming")
                // 402 / out-of-credits: not retryable, but the user must SEE
                // why the run stopped (a silent failure reads as "model is
                // failing"). Surface a provider-issue banner with the
                // actionable message before giving up.
                eventBus.publish(ProviderIssueStatusEvent(
                    providerName: providerLabel,
                    statusKind: .insufficientBalance,
                    statusCode: 402,
                    message: lastError?.localizedDescription
                        ?? "Provider has insufficient credits for this request.",
                    cooldownUntil: nil
                ))
                return .giveUp
            case .rateLimit(let wait):
                lastError = Self.mapToAppError(error, operation: "sendMessageStreaming")
                guard await sleepRespectingCancellation(nanoseconds: wait) else {
                    lastError = .aiServiceError("Request cancelled")
                    return .giveUp
                }
                return .retry
            case .network(let wait):
                lastError = Self.mapToAppError(error, operation: "sendMessageStreaming")
                networkIssueActive = true
                guard await sleepRespectingCancellation(nanoseconds: wait) else {
                    lastError = .aiServiceError("Request cancelled")
                    return .giveUp
                }
                return .retry
            case .networkExhausted:
                lastError = Self.mapToAppError(error, operation: "sendMessageStreaming")
                if networkIssueActive {
                    eventBus.publish(ProviderIssueStatusEvent(
                        providerName: providerLabel, statusKind: .resolved,
                        statusCode: nil, message: "", cooldownUntil: nil))
                }
                if Self.shouldDegradeOnTransportFailure(request.stage) {
                    return .degrade
                }
                return .giveUp
            case .generic(let wait):
                lastError = Self.mapToAppError(error, operation: "sendMessageStreaming")
                guard await sleepRespectingCancellation(nanoseconds: wait) else {
                    lastError = .aiServiceError("Request cancelled")
                    return .giveUp
                }
                return .retry
            case .surrender:
                lastError = Self.mapToAppError(error, operation: "sendMessageStreaming")
                if Self.shouldDegradeOnTransportFailure(request.stage) {
                    return .degrade
                }
                return .giveUp
            }
        }

        for attempt in 1...loopMax {
            if Task.isCancelled {
                return .failure(.aiServiceError("Request cancelled"))
            }

            let retryMessages: [ChatMessage]
            if request.preservesCache {
                retryMessages = sanitizedMessages
            } else if attempt > 1 {
                let retryReason = lastError?.localizedDescription ?? "previous attempt failed"
                let isEmptyResponseError = retryReason.contains("Empty response")
                let isMalformedToolCallError = retryReason.contains("Malformed tool call")
                let promptKey: String
                if isEmptyResponseError {
                    promptKey = "ConversationFlow/Corrections/empty_response_correction"
                } else if isMalformedToolCallError {
                    promptKey = "ConversationFlow/Corrections/malformed_tool_call_correction"
                } else {
                    promptKey = "ConversationFlow/Corrections/retry_context_message"
                }
                let retryPromptTemplate: String
                do {
                    retryPromptTemplate = try PromptRepository.shared.prompt(
                        key: promptKey,
                        projectRoot: request.projectRoot
                    )
                } catch {
                    return .failure(Self.mapToAppError(error, operation: "prompt.\(promptKey)"))
                }
                // Inject as a `user` message, not `system`: Anthropic-format
                // requests only honor `system` in the leading block, so a
                // trailing system message after tool results is silently
                // dropped — exactly when a retry correction is needed. A
                // user-role correction is universally honored.
                let retryContextMessage = ChatMessage(
                    role: .user,
                    content: retryPromptTemplate
                        .replacingOccurrences(of: "{{attempt}}", with: String(attempt))
                        .replacingOccurrences(of: "{{max_attempts}}", with: String(maxAttempts))
                        .replacingOccurrences(of: "{{retry_reason}}", with: retryReason)
                )
                retryMessages = sanitizedMessages + [retryContextMessage]
            } else {
                retryMessages = sanitizedMessages
            }

            let historyRequest = AIServiceHistoryRequest(
                messages: retryMessages,
                mediaAttachments: request.mediaAttachments,
                tools: filteredTools,
                mode: request.mode,
                projectRoot: request.projectRoot,
                runId: request.runId,
                stage: request.stage,
                conversationId: request.conversationId
            )

            let shouldUseStreaming = shouldUseStreamingForRequest(
                runId: request.runId,
                stage: request.stage,
                hasTools: !filteredTools.isEmpty,
                isRunningUnitTests: isUnitTestRun
            )

            // Use streaming in app runtime; disable in tests for deterministic harness telemetry
            if shouldUseStreaming, let runId = request.runId {
                eventBus.publish(LocalModelStreamingStatusEvent(
                    runId: runId,
                    message: "Sending request to inference server…"
                ))
                do {
                    let response = try await aiService.sendMessageStreaming(
                        historyRequest, runId: runId)
                    if Self.isEmptyResponse(response) && attempt < maxAttempts {
                        await AIToolTraceLogger.shared.log(type: "chat.empty_response_retry", data: [
                            "runId": runId,
                            "attempt": attempt,
                            "stage": request.stage?.rawValue ?? "unknown",
                            "contentLength": response.content?.count ?? 0,
                            "hasToolCalls": !(response.toolCalls?.isEmpty ?? true)
                        ])
                        lastError = .aiServiceError("Empty response: model returned no visible content")
                        let waitSeconds = retryDelayNanoseconds(
                            forAttempt: attempt,
                            stage: request.stage,
                            isRateLimitError: false,
                            isRunningUnitTests: isUnitTestRun
                        )
                        guard await sleepRespectingCancellation(nanoseconds: waitSeconds) else {
                            return .failure(.aiServiceError("Request cancelled"))
                        }
                        continue
                    }
                    // Malformed/truncated tool-call markup must NOT terminate
                    // the run — retry with a correction so the agent keeps
                    // working (previously treated as a valid answer, breaking
                    // the agentic loop mid-task).
                    if Self.isMalformedToolCallResponse(response),
                       !filteredTools.isEmpty, attempt < maxAttempts {
                        await AIToolTraceLogger.shared.log(type: "chat.malformed_tool_call_retry", data: [
                            "runId": runId,
                            "attempt": attempt,
                            "stage": request.stage?.rawValue ?? "unknown",
                            "contentLength": response.content?.count ?? 0,
                            "malformedCount": response.malformedToolCalls?.count ?? 0
                        ])
                        lastError = .aiServiceError("Malformed tool call: model emitted tool-call markup that could not be parsed")
                        let waitSeconds = retryDelayNanoseconds(
                            forAttempt: attempt,
                            stage: request.stage,
                            isRateLimitError: false,
                            isRunningUnitTests: isUnitTestRun
                        )
                        guard await sleepRespectingCancellation(nanoseconds: waitSeconds) else {
                            return .failure(.aiServiceError("Request cancelled"))
                        }
                        continue
                    }
                    if networkIssueActive {
                        eventBus.publish(ProviderIssueStatusEvent(
                            providerName: providerLabel, statusKind: .resolved,
                            statusCode: nil, message: "", cooldownUntil: nil))
                        networkIssueActive = false
                    }
                    return .success(response)
                } catch {
                    switch await handleRetry(error, attempt: attempt) {
                    case .retry:
                        continue
                    case .giveUp:
                        return .failure(lastError ?? .aiServiceError("sendMessageStreaming failed"))
                    case .degrade:
                        return .success(Self.degradedResponse())
                    }
                }
            } else if let runId = request.runId {
                eventBus.publish(LocalModelStreamingStatusEvent(
                    runId: runId,
                    message: "Sending request to inference server…"
                ))
                let result = await aiService.sendMessageResult(historyRequest)

                switch result {
                case .success(let response):
                    if Self.isEmptyResponse(response) && attempt < maxAttempts {
                        await AIToolTraceLogger.shared.log(type: "chat.empty_response_retry", data: [
                            "attempt": attempt,
                            "stage": request.stage?.rawValue ?? "unknown",
                            "contentLength": response.content?.count ?? 0,
                            "hasToolCalls": !(response.toolCalls?.isEmpty ?? true)
                        ])
                        lastError = .aiServiceError("Empty response: model returned no visible content")
                        let waitSeconds = retryDelayNanoseconds(
                            forAttempt: attempt,
                            stage: request.stage,
                            isRateLimitError: false,
                            isRunningUnitTests: isUnitTestRun
                        )
                        guard await sleepRespectingCancellation(nanoseconds: waitSeconds) else {
                            return .failure(.aiServiceError("Request cancelled"))
                        }
                        continue
                    }
                    if Self.isMalformedToolCallResponse(response),
                       !filteredTools.isEmpty, attempt < maxAttempts {
                        await AIToolTraceLogger.shared.log(type: "chat.malformed_tool_call_retry", data: [
                            "attempt": attempt,
                            "stage": request.stage?.rawValue ?? "unknown",
                            "contentLength": response.content?.count ?? 0,
                            "malformedCount": response.malformedToolCalls?.count ?? 0
                        ])
                        lastError = .aiServiceError("Malformed tool call: model emitted tool-call markup that could not be parsed")
                        let waitSeconds = retryDelayNanoseconds(
                            forAttempt: attempt,
                            stage: request.stage,
                            isRateLimitError: false,
                            isRunningUnitTests: isUnitTestRun
                        )
                        guard await sleepRespectingCancellation(nanoseconds: waitSeconds) else {
                            return .failure(.aiServiceError("Request cancelled"))
                        }
                        continue
                    }
                    if networkIssueActive {
                        eventBus.publish(ProviderIssueStatusEvent(
                            providerName: providerLabel, statusKind: .resolved,
                            statusCode: nil, message: "", cooldownUntil: nil))
                        networkIssueActive = false
                    }
                    return result
                case .failure(let error):
                    switch await handleRetry(error, attempt: attempt) {
                    case .retry:
                        continue
                    case .giveUp:
                        return .failure(lastError ?? .aiServiceError("sendMessageStreaming failed"))
                    case .degrade:
                        return .success(Self.degradedResponse())
                    }
                }
            }
        }

        return .failure(lastError ?? .unknown("ConversationManager: sendMessageWithRetry failed"))
    }

    /// A response that carries tool-call MARKUP but zero recoverable calls is
    /// a parsing failure — treating it as a valid answer broke the agentic
    /// loop (the run advanced/terminated with the work unexecuted).
    private static func isMalformedToolCallResponse(_ response: AIServiceResponse) -> Bool {
        if !(response.toolCalls?.isEmpty ?? true) { return false }
        if !(response.malformedToolCalls?.isEmpty ?? true) { return true }
        guard let content = response.content else { return false }
        let indicators = [
            "<|tool_call>", "<tool_call>", "<tool_code>",
            "<invoke ", "<tool name=", "<function=", "<minimax:tool_call>",
        ]
        if indicators.contains(where: { content.contains($0) }) { return true }
        return content.range(of: #"call:[a-zA-Z_][a-zA-Z0-9_]*\s*\{"#, options: .regularExpression) != nil
    }

    private static func isEmptyResponse(_ response: AIServiceResponse) -> Bool {
        let hasToolCalls = !(response.toolCalls?.isEmpty ?? true)
        if hasToolCalls { return false }
        guard let content = response.content else { return true }
        let split = ChatPromptBuilder.splitReasoning(from: content)
        let visibleContent = split.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visibleContent.isEmpty { return false }
        let hasReasoning = !(split.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return !hasReasoning
    }

    private static func mapToAppError(_ error: Error, operation: String) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .aiServiceError("AIService.\(operation) failed: \(error.localizedDescription)")
    }

    // MARK: - Graceful terminal finalization on transport exhaustion

    /// When the provider becomes unreachable, degrade to a terminal completion
    /// ONLY for the final-response stage (which never re-enters the tool loop, so
    /// there is no re-entry spiral). Mid-run tool-loop stalls still surface as a
    /// clean failure so the partial work on disk is preserved and the run ends.
    private static func shouldDegradeOnTransportFailure(_ stage: AIRequestStage?) -> Bool {
        guard degradeOnTransportFailure else { return false }
        return stage == .final_response
    }

    private static var degradeOnTransportFailure: Bool {
        ProcessInfo.processInfo.environment["COMPASS_DEGRADE_ON_TRANSPORT_FAILURE"]
            .flatMap { $0 == "1" || $0.lowercased() == "true" } ?? false
    }

    private static func degradedResponse() -> AIServiceResponse {
        AIServiceResponse(
            content: "[The AI provider became unreachable before this response could be fully generated. Any files already written remain in place — please retry to continue.]",
            toolCalls: [],
            reasoning: nil
        )
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let appError = error as? AppError {
            let normalized = appError.localizedDescription.lowercased()
            return normalized.contains("cancellationerror")
                || normalized.contains("request cancelled")
                || normalized.contains("request canceled")
                || normalized.contains("cancelled")
                || normalized.contains("canceled")
        }
        let normalized = String(describing: error).lowercased()
        return normalized.contains("cancellationerror")
            || normalized.contains("request cancelled")
            || normalized.contains("request canceled")
            || normalized.contains("cancelled")
            || normalized.contains("canceled")
    }

    private func sleepRespectingCancellation(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    func maxAttemptsForRequestStage(
        _ stage: AIRequestStage?,
        isRunningUnitTests: Bool = false
    ) -> Int {
        if isRunningUnitTests {
            switch stage {
            case .final_response:
                return 2
            case .tool_loop:
                return 3
            default:
                return 3
            }
        }

        switch stage {
        case .final_response:
            return 3
        case .tool_loop:
            return 5
        default:
            return 7
        }
    }

    func retryDelayNanoseconds(
        forAttempt attempt: Int,
        stage: AIRequestStage?,
        isRateLimitError: Bool,
        isRunningUnitTests: Bool = false
    ) -> UInt64 {
        guard isRateLimitError else {
            if isRunningUnitTests {
                return 1_000_000_000
            }
            return 2_000_000_000
        }

        let baseDelay = UInt64(pow(2.0, Double(attempt))) * 2_000_000_000
        let maxDelay: UInt64
        switch stage {
        case .final_response:
            maxDelay = 8_000_000_000
        case .tool_loop:
            maxDelay = 16_000_000_000
        default:
            maxDelay = 60_000_000_000
        }

        if isRunningUnitTests {
            let providerSafeMinimumDelay: UInt64 = 20_000_000_000
            return max(min(baseDelay, maxDelay), providerSafeMinimumDelay)
        }

        return min(baseDelay, maxDelay)
    }

    // MARK: - Retry classification (network vs rate-limit vs generic)

    private enum RetryAction {
        case cancel
        case insufficientBalance
        case rateLimit(delay: UInt64)
        case network(delay: UInt64)
        case networkExhausted
        case generic(delay: UInt64)
        case surrender
    }

    private func isRateLimitError(_ error: Error) -> Bool {
        let errStr = String(describing: error).lowercased()
        return errStr.contains("429") || errStr.contains("rate-limit")
            || errStr.contains("rate_limit")
    }

    private func isInsufficientBalanceError(_ error: Error) -> Bool {
        let errStr = String(describing: error).lowercased()
        return errStr.contains("402") || errStr.contains("insufficient balance")
            || errStr.contains("more credits")
    }

    private func classifyRetry(
        _ error: Error,
        attempt: Int,
        maxAttempts: Int,
        retryStart: Date,
        stage: AIRequestStage?,
        providerName: String,
        isUnitTestRun: Bool
    ) async -> RetryAction {
        if isCancellationError(error) || Task.isCancelled {
            return .cancel
        }
        if isInsufficientBalanceError(error) {
            return .insufficientBalance
        }
        switch await networkRetryResult(
            error, attempt: attempt, retryStart: retryStart,
            providerName: providerName, isUnitTestRun: isUnitTestRun
        ) {
        case .notNetwork:
            break
        case .retry(let delay):
            return .network(delay: delay)
        case .exhausted:
            return .networkExhausted
        }
        if isRateLimitError(error) {
            guard attempt < maxAttempts else { return .surrender }
            let wait = retryDelayNanoseconds(
                forAttempt: attempt, stage: stage,
                isRateLimitError: true, isRunningUnitTests: isUnitTestRun)
            return .rateLimit(delay: wait)
        }
        guard attempt < maxAttempts else { return .surrender }
        let wait = retryDelayNanoseconds(
            forAttempt: attempt, stage: stage,
            isRateLimitError: false, isRunningUnitTests: isUnitTestRun)
        return .generic(delay: wait)
    }

    private enum NetworkRetryResult {
        case notNetwork
        case retry(UInt64)
        case exhausted
    }

    // Network connectivity errors get a long, escalating retry schedule because they
    // are typically transient: short-wavelength wifi drops, packet loss/jitter,
    // switching networks, or modem/router power-cycles (often ~5 min). Each retry
    // publishes a non-modal provider-issue banner with a live countdown instead of
    // surfacing a hard popup. Schedule: 1s × 10s → 5s × 1min → 15s × 5min, then surrender.
    private func networkRetryResult(
        _ error: Error,
        attempt: Int,
        retryStart: Date,
        providerName: String,
        isUnitTestRun: Bool
    ) async -> NetworkRetryResult {
        guard isNetworkConnectivityError(error) else { return .notNetwork }
        let delay: TimeInterval
        if isUnitTestRun {
            // Keep harness runs bounded and fast; no long escalation.
            guard attempt < 3 else { return .exhausted }
            delay = 1
        } else {
            let elapsed = Date().timeIntervalSince(retryStart)
            let budget: TimeInterval = 10 + 60 + 300
            guard elapsed < budget else { return .exhausted }
            if elapsed < 10 {
                delay = 1
            } else if elapsed < 70 {
                delay = 5
            } else {
                delay = 15
            }
        }
        let nextRetry = Date().addingTimeInterval(delay)
        await AIToolTraceLogger.shared.log(type: "chat.network_retry", data: [
            "attempt": attempt,
            "elapsedSeconds": Int(Date().timeIntervalSince(retryStart)),
            "nextRetryInSeconds": Int(delay),
            "provider": providerName
        ])
        // Surface as a non-modal banner with a live countdown instead of a hard popup.
        eventBus.publish(ProviderIssueStatusEvent(
            providerName: providerName,
            statusKind: .networkOffline,
            statusCode: nil,
            message: "We can't reach the AI provider — retrying automatically…",
            cooldownUntil: nextRetry))
        return .retry(UInt64(delay * 1_000_000_000))
    }

    private func isNetworkConnectivityError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return Self.isTransientNetworkURLError(urlError.errorCode)
        }
        if let appErr = error as? AppError {
            switch appErr {
            case .networkError:
                return true
            case .aiServiceError(let message):
                return Self.networkPhraseSet.contains { message.localizedCaseInsensitiveContains($0) }
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return Self.isTransientNetworkURLError(nsError.code)
        }
        let description = error.localizedDescription.lowercased()
        return Self.networkPhraseSet.contains { description.contains($0) }
    }

    private static let networkPhraseSet: Set<String> = [
        "offline", "internet connection appears to be offline", "network connection was lost",
        "timed out", "could not connect", "cannot connect to", "network is unreachable",
        "connection reset", "connection dropped", "no network connection", "nsurlerror",
        "the network connection was lost", "request timed out", "connection failed"
    ]

    private static func isTransientNetworkURLError(_ code: Int) -> Bool {
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

    func shouldUseStreamingForRequest(
        runId: String?,
        stage: AIRequestStage?,
        hasTools: Bool,
        isRunningUnitTests: Bool
    ) -> Bool {
        runId != nil
            && stage != .final_response
    }

    private func isRunningUnitTests() -> Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
