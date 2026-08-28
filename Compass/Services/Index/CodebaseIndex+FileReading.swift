import Foundation

extension CodebaseIndex {
    public func readIndexedFile(path: String, startLine: Int? = nil, endLine: Int? = nil) throws -> String {
        let relative = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relative.isEmpty else {
            throw AppError.aiServiceError("Missing 'path' argument")
        }

        let fileURL: URL
        if relative.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: relative)
        } else {
            fileURL = projectRoot.appendingPathComponent(relative)
        }

        let standardizedFileURL = fileURL.standardizedFileURL
        let standardizedProjectRoot = projectRoot.standardizedFileURL
        if !standardizedFileURL.path.hasPrefix(standardizedProjectRoot.path + "/") {
            throw AppError.permissionDenied("index_read_file may only read files within the project root")
        }

        let absPath = standardizedFileURL.path
        let existsOnDisk = FileManager.default.fileExists(atPath: absPath)

        if !existsOnDisk {
            throw AppError.fileNotFound(relative)
        }

        let content = try String(contentsOf: standardizedFileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let total = lines.count

        let start = max(1, startLine ?? 1)
        let end = min(total, endLine ?? total)
        if start > end {
            return ""
        }

        var output: [String] = []
        output.reserveCapacity(end - start + 1)
        for lineNumber in start...end {
            let text = lines[lineNumber - 1]
            output.append(String(format: "%6d | %@", lineNumber, text))
        }

        return output.joined(separator: "\n")
    }
}
