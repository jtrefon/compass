import Foundation

public enum ReasoningOutcomeDeliveryState: String, Codable, Sendable {
    case done
    case needs_work
}

public struct ReasoningOutcome: Codable, Sendable {
    public let planDelta: String?
    public let nextAction: String?
    public let knownRisks: String?
    public let deliveryState: ReasoningOutcomeDeliveryState

    public init(
        planDelta: String?,
        nextAction: String?,
        knownRisks: String?,
        deliveryState: ReasoningOutcomeDeliveryState
    ) {
        self.planDelta = planDelta
        self.nextAction = nextAction
        self.knownRisks = knownRisks
        self.deliveryState = deliveryState
    }
}
