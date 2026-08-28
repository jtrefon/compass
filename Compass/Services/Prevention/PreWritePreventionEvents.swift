import Foundation

// MARK: - Pre-write prevention events

// Published by AIToolExecutor (runPreWritePreventionIfNeeded) and consumed by
// the prevention UI. Kept in their own file — historically they were bundled
// with the (now deleted) RAG retrieval events.

public struct PreWritePreventionCheckStartedEvent: Event {
    public let toolName: String
    public let candidateFileCount: Int

    public init(toolName: String, candidateFileCount: Int) {
        self.toolName = toolName
        self.candidateFileCount = candidateFileCount
    }
}

public struct PreWritePreventionCheckCompletedEvent: Event {
    public let toolName: String
    public let outcome: String
    public let findingCount: Int

    public init(toolName: String, outcome: String, findingCount: Int) {
        self.toolName = toolName
        self.outcome = outcome
        self.findingCount = findingCount
    }
}

public struct DuplicateRiskDetectedEvent: Event {
    public let summary: String
    public let severity: String

    public init(summary: String, severity: String) {
        self.summary = summary
        self.severity = severity
    }
}

public struct DeadCodeRiskDetectedEvent: Event {
    public let summary: String
    public let severity: String

    public init(summary: String, severity: String) {
        self.summary = summary
        self.severity = severity
    }
}

public struct DebtPressureUpdatedEvent: Event {
    public let duplicateRiskCount: Int
    public let deadCodeRiskCount: Int
    public let guardStatus: String

    public init(duplicateRiskCount: Int, deadCodeRiskCount: Int, guardStatus: String) {
        self.duplicateRiskCount = duplicateRiskCount
        self.deadCodeRiskCount = deadCodeRiskCount
        self.guardStatus = guardStatus
    }
}
