import Foundation

/// Why this exists: `URLSession.bytes(for:)` + `bytes.lines` has **no** stream-level
/// deadline. If a server sends SSE keep-alive comments (`: ping`) but never delivers
/// `[DONE]`, the consumption loop hangs forever (the keep-alives keep the connection
/// "active" so `timeoutIntervalForRequest` never fires). This wrapper enforces two
/// independent, cancellable deadlines and fails the stream with `StreamLivenessError`
/// so the caller's retry/backoff path can recover instead of stalling indefinitely.
enum StreamLivenessError: Error {
    /// No *meaningful* (non-comment) SSE line received for longer than `idle`.
    case idle
    /// The whole stream exceeded `absolute` regardless of activity.
    case absolute
}

/// Records consecutive transport/server (5xx) failures for the OpenRouter provider.
/// Once `failureThreshold` is reached, the breaker "trips" and routes subsequent
/// requests to `fallbackModelId` for `cooldown` seconds, then automatically resets
/// (half-open -> closed on the next successful request).
///
/// This is the Tier-2 resilience layer: a single model/provider stall degrades into
/// a completed request on a healthy model instead of failing the whole agent turn.
/// Client errors (4xx, auth, rate-limit) do NOT trip the breaker, because a
/// different model would not resolve them.
final class TransportCircuitBreaker: @unchecked Sendable {
    private let lock = NSLock()
    private var consecutiveFailures: Int = 0
    private var trippedUntil: Date?

    private var failureThreshold: Int {
        ProcessInfo.processInfo.environment["COMPASS_CIRCUIT_FAILURE_THRESHOLD"]
            .flatMap(Int.init) ?? 1
    }
    private var cooldown: TimeInterval {
        ProcessInfo.processInfo.environment["COMPASS_CIRCUIT_COOLDOWN_SEC"]
            .flatMap(TimeInterval.init) ?? 120
    }
    private var fallbackModelId: String? {
        let v = ProcessInfo.processInfo.environment["COMPASS_FALLBACK_MODEL_ID"] ?? ""
        return v.isEmpty ? nil : v
    }

    var isTripped: Bool {
        lock.lock(); defer { lock.unlock() }
        if let until = trippedUntil {
            if Date() < until { return true }
            trippedUntil = nil
            consecutiveFailures = 0
        }
        return false
    }

    func recordTransportOrServerFailure(_ error: Error) {
        guard Self.isTransportOrServerFailure(error) else { return }
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures += 1
        if consecutiveFailures >= max(1, failureThreshold) {
            trippedUntil = Date().addingTimeInterval(cooldown)
        }
    }

    func recordTransportSuccess() {
        lock.lock(); defer { lock.unlock() }
        consecutiveFailures = 0
        trippedUntil = nil
    }

    func effectiveModel(for primary: String) -> String {
        if isTripped, let fb = fallbackModelId, !fb.isEmpty {
            return fb
        }
        return primary
    }

    private static func isTransportOrServerFailure(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let ore = error as? OpenRouterServiceError {
            switch ore {
            case .streamTimeout: return true
            case .serverError(let code, _): return code >= 500
            default: return false
            }
        }
        let d = error.localizedDescription.lowercased()
        return d.contains("timed out")
            || d.contains("timeout")
            || d.contains("connection was lost")
            || d.contains("network connection was lost")
    }
}

/// Single shared breaker for the OpenRouter provider, so the transport layer
/// (where failures are recorded) and the request builder (where the fallback model
/// is selected) observe the same tripped state.
let openRouterCircuitBreaker = TransportCircuitBreaker()

/// Opt-in stream liveness diagnostics. Off unless `COMPASS_STREAM_DIAGNOSTICS` is set,
/// so production harness runs stay quiet; enable to trace stalls.
private let streamDiagnosticsEnabled = ProcessInfo.processInfo.environment["COMPASS_STREAM_DIAGNOSTICS"] != nil
private func streamDiag(_ message: String) {
    if streamDiagnosticsEnabled { /* print removed */ }
}

/// Tracks the last *meaningful* (non-comment) SSE line time so the concurrent
/// reader/watcher tasks can share it safely.
private actor LivenessClock {
    var last: ContinuousClock.Instant
    init(_ start: ContinuousClock.Instant) { self.last = start }
    func mark() { last = .now }
    func idleElapsed(now: ContinuousClock.Instant) -> Duration { last.duration(to: now) }
}

struct SSEStreamDeadline: Sendable {
    let idle: Duration
    let absolute: Duration
    let granularity: Duration

    /// Defaults are env-overridable (seconds) and fall back to safe production values.
    static func `default`() -> SSEStreamDeadline {
        let env = ProcessInfo.processInfo.environment
        let idleSec = env["COMPASS_STREAM_IDLE_TIMEOUT_SEC"].flatMap(TimeInterval.init) ?? 60
        let absSec = env["COMPASS_STREAM_ABSOLUTE_TIMEOUT_SEC"].flatMap(TimeInterval.init) ?? 120
        return SSEStreamDeadline(
            idle: .nanoseconds(Int((idleSec * 1_000_000_000).rounded())),
            absolute: .nanoseconds(Int((absSec * 1_000_000_000).rounded())),
            granularity: .nanoseconds(1_000_000_000)
        )
    }

    /// Returns an async throwing stream of the raw SSE lines from `sequence`. The stream
    /// fails with `StreamLivenessError` if either deadline is breached. SSE keep-alive
    /// comments (`:`) are treated as connection activity but do **not** reset the idle
    /// timer — only real `data:` lines count as meaningful progress.
    ///
    /// Generic over the source `AsyncSequence` (element `String`) so the liveness logic
    /// can be unit-tested without a live `URLSession.AsyncBytes`.
    func lines<S>(from sequence: S) -> AsyncThrowingStream<String, Error>
    where S: AsyncSequence & Sendable, S.Element == String {
        AsyncThrowingStream { continuation in
            let start = ContinuousClock.now
            let clock = LivenessClock(start)
            let reader = Task {
                do {
                    streamDiag("READER entering loop")
                    for try await line in sequence {
                        continuation.yield(line)
                        if !line.trimmingCharacters(in: .newlines).hasPrefix(":") {
                            await clock.mark()
                        }
                    }
                    streamDiag("READER loop ended normally")
                    continuation.finish()
                } catch {
                    streamDiag("READER loop threw: \(error)")
                    continuation.finish(throwing: error)
                }
            }
            let watcher = Task {
                while true {
                    try? await Task.sleep(for: granularity)
                    if Task.isCancelled { return }
                    let now = ContinuousClock.now
                    if start.duration(to: now) >= absolute {
                        streamDiag("WATCHER absolute fired elapsed=\(start.duration(to: now))")
                        continuation.finish(throwing: StreamLivenessError.absolute)
                        return
                    }
                    if await clock.idleElapsed(now: now) >= idle {
                        streamDiag("WATCHER idle fired elapsed=\(await clock.idleElapsed(now: now))")
                        continuation.finish(throwing: StreamLivenessError.idle)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                watcher.cancel()
            }
        }
    }
}

actor OpenRouterAPIClient {
    static let urlSessionConfiguration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return config
    }()

    struct RequestContext: Sendable {
        let baseURL: String
        let appName: String
        let referer: String
    }

    private struct Request: Sendable {
        let path: String
        let method: String
        let apiKey: String?
        let context: RequestContext
        let body: Data?
    }

    private struct OpenRouterModelResponse: Decodable {
        let data: [OpenRouterModel]
    }

    private var urlSession: URLSession

    init(urlSession: URLSession = URLSession(configuration: OpenRouterAPIClient.urlSessionConfiguration)) {
        self.urlSession = urlSession
    }

    /// Drops any in-flight (stalled) connection and creates a fresh session so a
    /// subsequent transport retry starts from a clean slate instead of reusing a
    /// wedged socket.
    private func resetSession() {
        urlSession.invalidateAndCancel()
        urlSession = URLSession(configuration: Self.urlSessionConfiguration)
    }

    /// Returns the model id to use for a request, substituting the circuit-breaker
    /// fallback when the primary model/provider is currently tripped. Nonisolated
    /// so the request builder (a different actor) can read the tripped state
    /// synchronously; the breaker guards its own state with a lock.
    nonisolated func effectiveModel(for primary: String) -> String {
        openRouterCircuitBreaker.effectiveModel(for: primary)
    }

    static func ssePayloads<S: Sequence>(from lines: S) -> [String] where S.Element == String {
        var payloads: [String] = []
        var eventDataLines: [String] = []

        func flushEvent() {
            guard !eventDataLines.isEmpty else { return }
            payloads.append(eventDataLines.joined(separator: "\n"))
            eventDataLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let rawLine = line.trimmingCharacters(in: .newlines)
            if rawLine.isEmpty {
                flushEvent()
                continue
            }
            if rawLine.hasPrefix(":") {
                continue
            }
            if rawLine.hasPrefix("data:") {
                var value = String(rawLine.dropFirst(5))
                if value.hasPrefix(" ") {
                    value.removeFirst()
                }
                eventDataLines.append(value)
            }
        }

        flushEvent()
        return payloads
    }

    func fetchModels(
        apiKey: String?,
        context: RequestContext
    ) async throws -> [OpenRouterModel] {
        let request = try makeRequest(Request(
            path: "models",
            method: "GET",
            apiKey: apiKey,
            context: context,
            body: nil
        ))

        let (data, response) = try await urlSession.data(for: request)
        let status = try httpStatus(from: response)
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8)
            throw OpenRouterServiceError.serverError(status, body: body)
        }
        let decoded = try JSONDecoder().decode(OpenRouterModelResponse.self, from: data)
        return decoded.data
    }

    func validateKey(
        apiKey: String,
        context: RequestContext
    ) async throws {
        _ = try await fetchModels(
            apiKey: apiKey,
            context: context
        )
    }

    func testModel(
        apiKey: String,
        model: String,
        context: RequestContext
    ) async throws -> TimeInterval {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "Ping for latency check. Reply with pong."]
            ],
            "max_tokens": 16,
            "temperature": 0.0
        ]

        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        let startTime = Date()
        _ = try await chatCompletion(
            apiKey: apiKey,
            context: context,
            body: body
        )
        return Date().timeIntervalSince(startTime)
    }

    /// Non-streaming chat completion with transparent transport-level retry.
    ///
    /// Connection failures (TCP/TLS drops, offline, timeouts) and HTTP 200
    /// responses with an empty/truncated body are retried on a fresh connection
    /// before this method returns. HTTP error statuses (auth, rate-limit, 5xx)
    /// are semantic and surfaced immediately. The caller — and therefore the
    /// agent — only ever observes a valid payload or a definitive failure.
    func chatCompletion(
        apiKey: String,
        context: RequestContext,
        body: Data
    ) async throws -> Data {
        let request = try makeRequest(Request(
            path: "chat/completions",
            method: "POST",
            apiKey: apiKey,
            context: context,
            body: body
        ))

        let maxAttempts = TransportRetryConfig.maxAttempts
        var lastConnectionError: Error?

        for attempt in 0..<maxAttempts {
            do {
                let (data, response) = try await urlSession.data(for: request)
                let status = try httpStatus(from: response)
                guard status == 200 else {
                    let body = String(data: data, encoding: .utf8)
                    let err = OpenRouterServiceError.serverError(status, body: body)
                    openRouterCircuitBreaker.recordTransportOrServerFailure(err)
                    throw err
                }
                if !data.isEmpty {
                    openRouterCircuitBreaker.recordTransportSuccess()
                    return data
                }
                // HTTP 200 but no body: a dropped/truncated response at the
                // transport layer. Retry transparently.
                lastConnectionError = nil
            } catch {
                if !Self.isTransportRetryable(error) {
                    throw error
                }
                lastConnectionError = error
                openRouterCircuitBreaker.recordTransportOrServerFailure(error)
            }

            if attempt < maxAttempts - 1 {
                try await TransportRetryConfig.backoff(attempt: attempt)
            }
        }

        if let error = lastConnectionError {
            throw error
        }
        openRouterCircuitBreaker.recordTransportOrServerFailure(OpenRouterServiceError.invalidResponse)
        throw OpenRouterServiceError.invalidResponse
    }

    /// Streaming chat completion with transparent transport-level retry.
    ///
    /// A connection drop, stream stall, or an HTTP 200 stream that closes having
    /// delivered zero content is retried on a fresh connection — entirely below
    /// the agent. Once any real content has been delivered to `onChunk`, retries
    /// stop and the stream is left to the coordinator for resumption. If every
    /// attempt delivers zero content (a genuinely empty model response), this
    /// returns normally so the coordinator can apply its empty-response correction;
    /// if every attempt is a connection failure, the last error is thrown so the
    /// coordinator can show its network-offline banner.
    func chatCompletionStreaming(
        apiKey: String,
        context: RequestContext,
        body: Data,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws {
        let maxAttempts = TransportRetryConfig.maxAttempts
        var lastConnectionError: Error?

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                resetSession()
            }
            do {
                let delivered = try await performStreamingAttempt(
                    apiKey: apiKey,
                    context: context,
                    body: body,
                    onChunk: onChunk
                )
                if delivered {
                    openRouterCircuitBreaker.recordTransportSuccess()
                    return
                }
                // Stream connected and closed but delivered no content: a
                // truncated/dropped response. Retry transparently.
                lastConnectionError = nil
            } catch let StreamAttemptError.retryable(underlying) {
                lastConnectionError = underlying
                openRouterCircuitBreaker.recordTransportOrServerFailure(underlying)
            } catch let StreamAttemptError.definitive(underlying) {
                openRouterCircuitBreaker.recordTransportOrServerFailure(underlying)
                throw underlying
            }

            if attempt < maxAttempts - 1 {
                try await TransportRetryConfig.backoff(attempt: attempt)
            }
        }

        if let error = lastConnectionError {
            throw error
        }
    }

    /// A single streaming attempt. Returns `true` if any content was delivered to
    /// `onChunk`. Connection/stall failures before content are surfaced as
    /// `StreamAttemptError.retryable`; semantic HTTP errors and stalls after
    /// content are `StreamAttemptError.definitive` (not retried here).
    private func performStreamingAttempt(
        apiKey: String,
        context: RequestContext,
        body: Data,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> Bool {
        var request = try makeStreamingRequest(Request(
            path: "chat/completions",
            method: "POST",
            apiKey: apiKey,
            context: context,
            body: body
        ))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let deadline = SSEStreamDeadline.default()

        do {
            streamDiag("bytes(for:) calling (absolute=\(deadline.absolute), idle=\(deadline.idle))")
            let (bytes, response) = try await urlSession.bytes(for: request)
            streamDiag("bytes(for:) returned")
            let status = try httpStatus(from: response)
            guard status == 200 else {
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                }
                let errorBody = String(data: errorData, encoding: .utf8)
                throw StreamAttemptError.definitive(
                    OpenRouterServiceError.serverError(status, body: errorBody))
            }

            var eventDataLines: [String] = []
            var deliveredContent = false

            func flushEvent() {
                guard !eventDataLines.isEmpty else { return }
                onChunk(eventDataLines.joined(separator: "\n"))
                deliveredContent = true
                eventDataLines.removeAll(keepingCapacity: true)
            }

            do {
                for try await line in deadline.lines(from: bytes.lines) {
                    let rawLine = line.trimmingCharacters(in: .newlines)
                    if rawLine.isEmpty {
                        flushEvent()
                        continue
                    }
                    if rawLine.hasPrefix(":") {
                        continue
                    }
                    if rawLine.hasPrefix("data:") {
                        var dataPart = String(rawLine.dropFirst(5))
                        if dataPart.hasPrefix(" ") {
                            dataPart.removeFirst()
                        }
                        if dataPart == "[DONE]" {
                            flushEvent()
                            break
                        }
                        eventDataLines.append(dataPart)
                    }
                }
            } catch let error as StreamLivenessError {
                // A stall is a server/protocol-side issue: the connection is still
                // alive and ACKing SSE keep-alives, so it is not a transport drop.
                // Surface it definitively so the coordinator can resume — never
                // transparently retry, which would open a redundant connection to a
                // stuck server (and defeat the stall-detection harness test).
                throw StreamAttemptError.definitive(
                    OpenRouterServiceError.streamTimeout(error))
            } catch {
                throw deliveredContent
                    ? StreamAttemptError.definitive(error)
                    : StreamAttemptError.retryable(error)
            }

            flushEvent()
            return deliveredContent
        } catch let sae as StreamAttemptError {
            throw sae
        } catch {
            // urlSession.bytes(for:) threw before any content: a transport drop.
            throw StreamAttemptError.retryable(error)
        }
    }

    /// Distinguishes a transport failure we may transparently retry (`retryable`,
    /// no content delivered yet) from a definitive failure that must propagate to
    /// the coordinator (`definitive`).
    private enum StreamAttemptError: Error {
        case retryable(Error)
        case definitive(Error)
    }

    /// Transparent transport-retry policy. Connection drops, stalls, and
    /// empty/truncated bodies are retried on a fresh connection with escalating
    /// backoff. Configurable via environment for debugging/tests.
    private enum TransportRetryConfig {
        /// Default 3 attempts (2 retries) — transient connection drops are
        /// common and the backoff machinery only pays off if it can run.
        static var maxAttempts: Int {
            Int(ProcessInfo.processInfo.environment["COMPASS_TRANSPORT_RETRY_ATTEMPTS"] ?? "") ?? 3
        }

        static var baseDelay: TimeInterval {
            TimeInterval(ProcessInfo.processInfo.environment["COMPASS_TRANSPORT_RETRY_BASE_SEC"] ?? "") ?? 0.5
        }

        static var maxDelay: TimeInterval {
            TimeInterval(ProcessInfo.processInfo.environment["COMPASS_TRANSPORT_RETRY_MAX_SEC"] ?? "") ?? 8.0
        }

        static func backoff(attempt: Int) async throws {
            let delay = min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private static func isTransportRetryable(_ error: Error) -> Bool {
        if let server = error as? OpenRouterServiceError {
            switch server {
            case .serverError, .invalidResponse, .invalidURL, .missingAPIKey, .emptyModel:
                return false
            case .streamTimeout:
                return true
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable, .dataNotAllowed, .internationalRoamingOff,
                 .callIsActive, .secureConnectionFailed,
                 .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }
        return false
    }

    func fetchKiloBalance(
        apiKey: String,
        apiBaseURL: String
    ) async throws -> Decimal? {
        guard let base = URL(string: apiBaseURL) else {
            throw OpenRouterServiceError.invalidURL
        }
        let url = base.appendingPathComponent("api/profile/balance")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await urlSession.data(for: request)
        let status = try httpStatus(from: response)
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8)
            throw OpenRouterServiceError.serverError(status, body: body)
        }

        struct BalanceResponse: Decodable {
            let balance: Decimal?
        }

        return try JSONDecoder().decode(BalanceResponse.self, from: data).balance
    }

    func fetchDeepSeekBalance(
        apiKey: String,
        apiBaseURL: String
    ) async throws -> Decimal? {
        guard let base = URL(string: apiBaseURL) else {
            throw OpenRouterServiceError.invalidURL
        }
        let url = base.appendingPathComponent("user/balance")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        let status = try httpStatus(from: response)
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8)
            throw OpenRouterServiceError.serverError(status, body: body)
        }

        struct DeepSeekBalanceResponse: Decodable {
            struct BalanceInfo: Decodable {
                let currency: String?
                let totalBalance: String?
                let grantedBalance: String?
                let toppedUpBalance: String?
                
                enum CodingKeys: String, CodingKey {
                    case currency
                    case totalBalance = "total_balance"
                    case grantedBalance = "granted_balance"
                    case toppedUpBalance = "topped_up_balance"
                }
            }
            let isAvailable: Bool?
            let balanceInfos: [BalanceInfo]?
            
            enum CodingKeys: String, CodingKey {
                case isAvailable = "is_available"
                case balanceInfos = "balance_infos"
            }
        }

        let decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        // Return total balance in USD from first balance info
        if let balanceStr = decoded.balanceInfos?.first?.totalBalance {
            return Decimal(string: balanceStr)
        }
        return nil
    }

    private func makeRequest(_ request: Request) throws -> URLRequest {
        try makeURLRequest(request)
    }

    private func makeStreamingRequest(_ request: Request) throws -> URLRequest {
        var urlRequest = try makeURLRequest(request)
        // Disable automatic decompression to get raw bytes for SSE parsing
        urlRequest.setValue("no-transform", forHTTPHeaderField: "Accept-Encoding")
        return urlRequest
    }

    private func makeURLRequest(_ request: Request) throws -> URLRequest {
        guard let base = URL(string: request.context.baseURL) else { throw OpenRouterServiceError.invalidURL }
        let url = base.appendingPathComponent(request.path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        if let apiKey = request.apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if !request.context.referer.isEmpty {
            urlRequest.setValue(request.context.referer, forHTTPHeaderField: "HTTP-Referer")
        }
        if !request.context.appName.isEmpty {
            urlRequest.setValue(request.context.appName, forHTTPHeaderField: "X-Title")
        }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    private func httpStatus(from response: URLResponse) throws -> Int {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterServiceError.invalidResponse
        }
        return httpResponse.statusCode
    }
}
