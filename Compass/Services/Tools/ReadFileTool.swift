//
//  ReadFileTool.swift
//  Compass
//
//  Created by AI Assistant on 11/01/2026.
//

import Foundation

/// Read content of a file
struct ReadFileTool: AITool {
    let name = "read"
    let description = "Read a file at path. Large files: use start_line/end_line (numbered, paginated). Minified files: use char_offset/char_limit."
    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Project-root-relative path to a FILE (not a directory). Use `ls` to list directory contents."
                ],
                "start_line": [
                    "type": "integer",
                    "description": "Optional 1-based start line to read from (use for ranged reads of large files)."
                ],
                "end_line": [
                    "type": "integer",
                    "description": "Optional 1-based end line to read through (inclusive)."
                ],
                "char_offset": [
                    "type": "integer",
                    "description": "Optional 0-based character offset for minified/single-line files (use with char_limit)."
                ],
                "char_limit": [
                    "type": "integer",
                    "description": "Optional number of characters to return when using char_offset."
                ]
            ],
            "required": ["path"]
        ]
    }

    let fileSystemService: FileSystemService
    let pathValidator: PathValidator

    func execute(arguments: ToolArguments) async throws -> String {
        let arguments = arguments.raw
        guard let path = arguments["path"] as? String else {
            throw AppError.aiServiceError("Missing 'path' argument for read_file")
        }
        let context = ToolInvocationContext.from(arguments: arguments)
        let url = try pathValidator.validateAndResolve(path)
        let relativePath = pathValidator.relativePath(for: url)

        // Check if path is a directory — read only works on files
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            throw AppError.aiServiceError("Cannot read '\(relativePath)' — it's a directory. Use `ls` to list its contents.")
        }

        let content = try fileSystemService.readFile(at: url)

        await ToolFileAccessLedger.shared.recordRead(
            relativePath: relativePath,
            conversationId: context.conversationId
        )

        let startLine = parseLineNumber(arguments["start_line"])
        let endLine = parseLineNumber(arguments["end_line"])
        let charOffset = parseLineNumber(arguments["char_offset"])
        let charLimit = parseLineNumber(arguments["char_limit"])

        if charOffset != nil || charLimit != nil {
            return extractCharRange(from: content, offset: charOffset, limit: charLimit)
        }

        guard startLine != nil || endLine != nil else {
            return content
        }

        let totalLines = content.components(separatedBy: .newlines).count
        return extractLineRange(
            from: content,
            startLine: startLine ?? 1,
            endLine: endLine,
            totalLines: totalLines
        )
    }

    private func parseLineNumber(_ value: Any?) -> Int? {
        switch value {
        case let number as Int:
            return number
        case let number as Int32:
            return Int(number)
        case let number as Int64:
            return Int(number)
        case let number as Double:
            return Int(number)
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func extractLineRange(from content: String, startLine: Int, endLine: Int?, totalLines: Int) -> String {
        let allLines = content.components(separatedBy: .newlines)
        guard !allLines.isEmpty else { return "" }

        let safeStart = min(max(1, startLine), allLines.count)
        let safeEnd = min(max(safeStart, endLine ?? allLines.count), allLines.count)

        guard safeStart <= safeEnd else { return "" }
        let indexedSlice = (safeStart...safeEnd).map { lineNumber in
            "\(lineNumber): \(allLines[lineNumber - 1])"
        }
        let body = indexedSlice.joined(separator: "\n")
        let footer = "\n\n(Showing lines \(safeStart)–\(safeEnd) of \(totalLines). Use start_line=\(safeEnd + 1) to continue.)"
        return body + footer
    }

    private func extractCharRange(from content: String, offset: Int?, limit: Int?) -> String {
        let start = max(0, offset ?? 0)
        guard start < content.count else { return "" }
        let end = limit.map { min(content.count, start + max(0, $0)) } ?? content.count
        guard start < end else { return "" }
        let slice = String(content[content.index(content.startIndex, offsetBy: start)..<content.index(content.startIndex, offsetBy: end)])
        let footer = "\n\n(Showing chars \(start)–\(end) of \(content.count). Use char_offset=\(end) to continue.)"
        return slice + footer
    }
}
