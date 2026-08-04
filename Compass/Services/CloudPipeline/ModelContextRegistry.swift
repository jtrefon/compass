import Foundation

/// Process-wide cache of per-model context windows (tokens), populated from
/// the OpenRouter model catalog whenever it is fetched (UsageTracker, model
/// picker). Lets `PipelineProcessor` bound requests to the ACTIVE model's real
/// window instead of assuming a 262K default for every model.
final class ModelContextRegistry: @unchecked Sendable {
    static let shared = ModelContextRegistry()

    private let lock = NSLock()
    private var contextLengthByModelId: [String: Int] = [:]

    private init() {}

    func setContextLength(_ length: Int, for modelID: String) {
        guard length > 0, !modelID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        contextLengthByModelId[modelID] = length
    }

    func contextLength(for modelID: String?) -> Int? {
        guard let modelID, !modelID.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return contextLengthByModelId[modelID]
    }

    func setContextLengths(_ lengths: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        for (id, length) in lengths where length > 0 {
            contextLengthByModelId[id] = length
        }
    }
}
