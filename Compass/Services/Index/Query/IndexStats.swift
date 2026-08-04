import Foundation

public struct IndexStats: Sendable {
    public let indexedResourceCount: Int
    public let aiEnrichedResourceCount: Int
    public let aiEnrichableProjectFileCount: Int
    public let totalProjectFileCount: Int
    public let symbolCount: Int
    public let classCount: Int
    public let structCount: Int
    public let enumCount: Int
    public let protocolCount: Int
    public let functionCount: Int
    public let variableCount: Int
    public let databaseSizeBytes: Int64
    public let databasePath: String
    public let isDatabaseInWorkspace: Bool
    public let averageQualityScore: Double
    public let averageAIQualityScore: Double

    public init(
        indexedResourceCount: Int,
        aiEnrichedResourceCount: Int,
        aiEnrichableProjectFileCount: Int,
        totalProjectFileCount: Int,
        symbolCount: Int,
        classCount: Int,
        structCount: Int,
        enumCount: Int,
        protocolCount: Int,
        functionCount: Int,
        variableCount: Int,
        databaseSizeBytes: Int64,
        databasePath: String,
        isDatabaseInWorkspace: Bool,
        averageQualityScore: Double,
        averageAIQualityScore: Double
    ) {
        self.indexedResourceCount = indexedResourceCount
        self.aiEnrichedResourceCount = aiEnrichedResourceCount
        self.aiEnrichableProjectFileCount = aiEnrichableProjectFileCount
        self.totalProjectFileCount = totalProjectFileCount
        self.symbolCount = symbolCount
        self.classCount = classCount
        self.structCount = structCount
        self.enumCount = enumCount
        self.protocolCount = protocolCount
        self.functionCount = functionCount
        self.variableCount = variableCount
        self.databaseSizeBytes = databaseSizeBytes
        self.databasePath = databasePath
        self.isDatabaseInWorkspace = isDatabaseInWorkspace
        self.averageQualityScore = averageQualityScore
        self.averageAIQualityScore = averageAIQualityScore
    }
}
