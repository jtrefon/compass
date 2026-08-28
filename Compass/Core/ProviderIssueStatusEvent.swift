import Foundation

public struct ProviderIssueStatusEvent: Event {
    public enum StatusKind: String, Equatable {
        case resolved
        case rateLimited
        case unavailable
        case authentication
        case transport
        case networkOffline
        case insufficientBalance
        case unknown
    }

    public let providerName: String
    public let statusKind: StatusKind
    public let statusCode: Int?
    public let message: String
    public let cooldownUntil: Date?

    public init(
        providerName: String,
        statusKind: StatusKind,
        statusCode: Int?,
        message: String,
        cooldownUntil: Date?
    ) {
        self.providerName = providerName
        self.statusKind = statusKind
        self.statusCode = statusCode
        self.message = message
        self.cooldownUntil = cooldownUntil
    }
}
