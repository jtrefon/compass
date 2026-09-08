import Foundation

struct ReadFileTool: AITool {
    let name = "read"
    let description = "Read a file at path. Use limit=N to cap lines shown (default 50). Use start_line/end_line for line ranges, char_offset/char_limit for minified files."

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Project-root-relative path to a FILE (not a directory)."
                ],
                "limit": [
                    "type": "integer",
                    "description": "Max lines to return (default 50, 0 = unlimited). Use with offset=N for pagination."
                ],
                "offset": [
                    "type": "integer",
                    "description": "0-based line offset to start from (default 0)."
                ],
                "start_line": [
                    "type": "integer",
                    "description": "1-based start line (legacy, prefer limit/offset)."
                ],
                "end_line": [
                    "type": "integer",
                    "description": "1-based end line (legacy, prefer limit/offset)."
                ],
                "char_offset": [
                    "type": "integer",
                    "description": "0-based character offset for minified files."
                ],
                "char_limit": [
                    "type": "integer",
                    "description": "Number of characters to return."
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

        if startLine != nil || endLine != nil {
            let totalLines = content.components(separatedBy: .newlines).count
            return extractLineRange(from: content, startLine: startLine ?? 1, endLine: endLine, totalLines: totalLines)
        }

        let limit = parseLineNumber(arguments["limit"]) ?? 50
        let offset = parseLineNumber(arguments["offset"]) ?? 0
        return extractPage(from: content, limit: limit, offset: offset)
    }

    private func extractPage(from content: String, limit: Int, offset: Int) -> String {
        let allLines = content.components(separatedBy: .newlines)
        let totalLines = allLines.count
        let safeOffset = max(0, min(offset, totalLines))

        if limit <= 0 {
            return formatLineRange(allLines, start: 0, end: totalLines - 1, totalLines: totalLines, startLineNum: 1)
        }

        let end = min(safeOffset + limit, totalLines)
        let body = formatLineRange(allLines, start: safeOffset, end: end - 1, totalLines: totalLines, startLineNum: safeOffset + 1)

        if end >= totalLines {
            return body
        }

        return body + "\n\n[Showing lines \(safeOffset + 1)-\(end) of \(totalLines). Use limit=\(limit) offset=\(end) to continue.]"
    }

    private func formatLineRange(_ allLines: [String], start: Int, end: Int, totalLines: Int, startLineNum: Int) -> String {
        guard start <= end, start < allLines.count else { return "" }
        let safeEnd = min(end, allLines.count - 1)
        let indexedSlice = (startLineNum...(startLineNum + (safeEnd - start))).map { lineNumber in
            "\(lineNumber): \(allLines[lineNumber - 1])"
        }
        return indexedSlice.joined(separator: "\n")
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

    private func parseLineNumber(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Int32: return Int(number)
        case let number as Int64: return Int(number)
        case let number as Double: return Int(number)
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }
}
