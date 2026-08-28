import Foundation

struct DatabaseScopedPathQueryBuilder {
    static func rootPrefix(projectRoot: URL) -> String {
        let rootPath = projectRoot.standardizedFileURL.path
        return rootPath.hasSuffix("/") ? rootPath : (rootPath + "/")
    }

    static func fileExtensionPredicates(allowedExtensions: Set<String>) -> String {
        allowedExtensions
            .map { _ in "LOWER(path) LIKE ?" }
            .sorted()
            .joined(separator: " OR ")
    }

    static func fileExtensionParameters(allowedExtensions: Set<String>) -> [Any] {
        allowedExtensions.sorted().map { "%.\($0)" }
    }
}
