import Foundation

struct FindFileTool: AITool {
    let name = "glob"
    let description = "Find files by name with optional max_results and offset pagination. Searches from the project root by default — no prior `ls` needed. PAGINATION: when results show a 'showing X-Y of Z' footer, use offset=Y max_results=<page size> for the next page."
    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "pattern": [
                    "type": "string",
                    "description": "The name pattern to search for (e.g., 'career-register', 'ProfileView'). " +
                        "Partial matches allowed — any filename containing the pattern will be returned."
                ],
                "path": [
                    "type": "string",
                    "description": "Optional subdirectory to scope the search (e.g. 'wp-content/plugins'). " +
                        "Defaults to the project root — omit this parameter to search everywhere."
                ],
                "max_results": [
                    "type": "integer",
                    "description": "Maximum file names to return (default 50, max 200)."
                ],
                "offset": [
                    "type": "integer",
                    "description": "Number of results to skip for pagination (default 0). Use with max_results to page through large result sets."
                ]
            ],
            "required": ["pattern"]
        ]
    }

    let pathValidator: PathValidator

    func execute(arguments: ToolArguments) async throws -> String {
        let arguments = arguments.raw
        guard let pattern = arguments["pattern"] as? String else {
            throw AppError.aiServiceError("Missing 'pattern' argument for glob")
        }
        let path = (arguments["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePath = (path?.isEmpty == false) ? path! : "."

        let maxResults = min(200, max(1, arguments["max_results"] as? Int ?? 50))
        let offset = max(0, arguments["offset"] as? Int ?? 0)

        let url = try pathValidator.validateAndResolve(effectivePath)
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var allMatches: [String] = []
        let lowerPattern = pattern.lowercased()

        while let fileURL = enumerator?.nextObject() as? URL {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if ToolFileExclusion.isExcluded(url: fileURL) {
                    enumerator?.skipDescendants()
                }
                continue
            }

            let fileName = fileURL.lastPathComponent.lowercased()
            if fileName.contains(lowerPattern) {
                let relativePath = fileURL.relativeTo(url)
                allMatches.append(relativePath)
            }

            if allMatches.count >= offset + maxResults {
                break
            }
        }

        let page = offset > 0 ? Array(allMatches.dropFirst(offset)) : allMatches
        let totalAvailable = allMatches.count

        if page.isEmpty {
            return "No files found matching '\(pattern)'."
        }

        var output = "Found \(totalAvailable) file(s) matching '\(pattern)':\n"
        output += page.joined(separator: "\n")

        if totalAvailable > offset + maxResults {
            let shownEnd = offset + page.count
            output += "\n\n[showing \(offset + 1)-\(shownEnd) of \(totalAvailable) — use `offset=\(shownEnd)` max_results=\(maxResults) for the next page]"
        } else if offset > 0 {
            output += "\n\n[showing remaining \(page.count) of \(totalAvailable) — end of results]"
        }

        return output
    }
}