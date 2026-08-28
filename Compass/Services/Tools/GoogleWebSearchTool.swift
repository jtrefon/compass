import Foundation

/// Fast web search tool using Google via WKWebView.
/// Returns structured list of results (title, URL, snippet) for top matches.
/// Does NOT maintain a browsing session — for deep browsing use `web_browse`.
struct GoogleWebSearchTool: AITool {
    let name = "web_search"
let description = "Search the web using Google."

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Search query to send to Google."
                ],
                "max_results": [
                    "type": "integer",
                    "description": "Maximum number of results to return (default 10, max 20)."
                ]
            ],
            "required": ["query"]
        ]
    }

    func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        guard let query = raw["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: 'query' is required and must not be empty."
        }

        let maxResults = min(20, max(1, raw["max_results"] as? Int ?? 10))

        return try await GoogleWebSearchEngine.shared.search(query: query, maxResults: maxResults)
    }
}
