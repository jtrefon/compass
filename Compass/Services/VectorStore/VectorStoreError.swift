import Foundation

public enum VectorStoreError: Error, LocalizedError {
    case faissError(String)
    case invalidDimension(expected: Int, got: Int)
    case indexNotLoaded
    case emptyVector
    case metadataError(String)
    case serializationError(String)
    case idMappingError(String)

    public var errorDescription: String? {
        switch self {
        case .faissError(let msg):
            return "FAISS error: \(msg)"
        case .invalidDimension(let expected, let got):
            return "Invalid dimension: expected \(expected), got \(got)"
        case .indexNotLoaded:
            return "Vector index not loaded"
        case .emptyVector:
            return "Cannot index an empty vector"
        case .metadataError(let msg):
            return "Metadata error: \(msg)"
        case .serializationError(let msg):
            return "Serialization error: \(msg)"
        case .idMappingError(let msg):
            return "ID mapping error: \(msg)"
        }
    }
}
