import Foundation

/// List files in a directory
struct ListFilesTool: AITool {
    let name = "ls"
    let description = "List files and directories under a path with optional name filter, limit, and offset pagination. Vendor directories are marked (excluded). PAGINATION: when results show a 'showing X-Y of Z' footer, use offset=Y limit=<page size> for the next page."
    var parameters: [String: Any] {
        FileToolParameterSchemaBuilder.objectSchema(
            properties: [
                "path": FileToolParameterSchemaBuilder.pathProperty(
                    description: "Directory path to list (absolute or project-root-relative). Defaults to project root when omitted."
                ),
                "query": [
                    "type": "string",
                    "description": "Optional case-insensitive filename filter (substring match)."
                ],
                "filter": [
                    "type": "string",
                    "description": "Alias for query."
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 1000,
                    "description": "Maximum number of entries to return."
                ],
                "offset": [
                    "type": "integer",
                    "minimum": 0,
                    "description": "Number of entries to skip for pagination (default 0). Use with limit to page through directories."
                ]
            ],
            required: []
        )
    }
    let pathValidator: PathValidator

    func execute(arguments: ToolArguments) async throws -> String {
        let arguments = arguments.raw
        let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath = path?.isEmpty == false ? path! : "."
        let query = ((arguments["query"] as? String) ?? (arguments["filter"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let limit = max(1, min(1000, arguments["limit"] as? Int ?? 200))
        let offset = max(0, arguments["offset"] as? Int ?? 0)

        let url = try pathValidator.validateAndResolve(resolvedPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return ""
        }
        guard isDirectory.boolValue else {
            return url.lastPathComponent
        }
        var contents = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        if let query, !query.isEmpty {
            contents = contents.filter { $0.lastPathComponent.lowercased().contains(query) }
        }

        let totalCount = contents.count
        let sorted = contents
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }
        let page = offset > 0 ? Array(sorted.dropFirst(offset)) : sorted
        let pageEntries = page.prefix(limit)
            .map { fileURL -> String in
                let isDirectory = (try? fileURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]).isDirectory) ?? false
                let name = isDirectory ? "\(fileURL.lastPathComponent)/" : fileURL.lastPathComponent
                if isDirectory, ToolFileExclusion.isExcluded(url: fileURL) {
                    return "\(name) (excluded)"
                }
                return name
            }

        var output = pageEntries.joined(separator: "\n")
        if totalCount > offset + limit {
            let shownStart = offset + 1
            let shownEnd = min(offset + limit, totalCount)
            output += "\n\n[showing \(shownStart)-\(shownEnd) of \(totalCount) entries — use `offset=\(shownEnd)` limit=\(limit) for the next page]"
        } else if offset > 0 {
            output += "\n\n[showing remaining \(pageEntries.count) of \(totalCount) entries — end of results]"
        }
        return output
    }
}
