import Foundation

struct LocalModelGenerationPerformanceSnapshot: Sendable {
    let modelId: String
    let inferenceConfiguration: LocalModelInferenceConfiguration
    let loadMilliseconds: Int
    let totalMilliseconds: Int
    let promptTokenCount: Int?
    let promptMilliseconds: Int?
    let promptTokensPerSecond: Double?
    let generationTokenCount: Int?
    let generationMilliseconds: Int?
    let generationTokensPerSecond: Double?
    let toolCallCount: Int
    let outputCharacterCount: Int
    let rssBeforeLoadMB: Int
    let rssAfterLoadMB: Int
    let rssAfterGenerationMB: Int
    let timestamp: Date
}

actor LocalModelGenerationPerformanceRecorder {
    static let shared = LocalModelGenerationPerformanceRecorder()

    private var snapshots: [LocalModelGenerationPerformanceSnapshot] = []
    private let maxSnapshots = 100

    func clear() {
        snapshots.removeAll()
    }

    func record(_ snapshot: LocalModelGenerationPerformanceSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
    }

    func latest() -> LocalModelGenerationPerformanceSnapshot? {
        snapshots.last
    }
}
