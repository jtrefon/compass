import Foundation

public struct VectorStoreConfiguration: Sendable {
    public let storePath: URL
    public let dimensions: Int
    public let factoryString: String
    public let embeddingModel: String

    public init(
        storePath: URL,
        dimensions: Int = 384,
        factoryString: String = "IDMap,Flat",
        embeddingModel: String = "bge-small-en-v1.5"
    ) {
        self.storePath = storePath
        self.dimensions = dimensions
        self.factoryString = factoryString
        self.embeddingModel = embeddingModel
    }

    public var indexFileURL: URL {
        storePath.appendingPathComponent("index.faiss")
    }

    public var metadataFileURL: URL {
        storePath.appendingPathComponent("metadata.json")
    }

    public static func `default`(basePath: URL) -> VectorStoreConfiguration {
        let storePath = basePath.appendingPathComponent(AppConstantsFileSystem.projectDirName).appendingPathComponent("vector_store")
        return VectorStoreConfiguration(storePath: storePath)
    }
}
