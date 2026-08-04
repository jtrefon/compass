import Foundation

/// Service for interacting with the local file system.
public final class FileSystemService: Sendable {
    public init() {}

    public func readFileResult(at url: URL) -> Result<String, AppError> {
        Result {
            try readFile(at: url)
        }
        .mapError { AppError.fileOperationFailed("read file", underlying: $0) }
    }

    public func writeFileResult(content: String, to url: URL) -> Result<Void, AppError> {
        Result {
            try writeFile(content: content, to: url)
        }
        .mapError { AppError.fileOperationFailed("write file", underlying: $0) }
    }

    public func writeFileResult(content: String, toPath path: String) -> Result<Void, AppError> {
        Result {
            try writeFile(content: content, toPath: path)
        }
        .mapError { AppError.fileOperationFailed("write file", underlying: $0) }
    }

    /// Reads the content of a file at the specified URL.
    public func readFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }

        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }

        // Lossy fallback to ensure the editor shows something instead of appearing broken.
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes the content to a file at the specified URL.
    public func writeFile(content: String, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes the content to a file at the specified path.
    public func writeFile(content: String, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try writeFile(content: content, to: url)
    }
}
