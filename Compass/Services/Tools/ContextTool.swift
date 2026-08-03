import Foundation

/// Retrieves prior conversation context from the FAISS vector store.
///
/// The model calls this when it needs to recall prior findings, decisions,
/// or code patterns — either from earlier in the same session (after
/// context trimming) or from previous sessions entirely.
///
/// This is the ACTIVE RAG tool — the model decides when to retrieve,
/// rather than having context silently injected.
struct ContextTool: AITool {
    let name = "context"
    let description = "Retrieve prior conversation context from the knowledge store. Use after context has been trimmed, when you need to recall findings, decisions, or code patterns from earlier in this session or previous sessions."

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "What you need to recall. Be specific about the topic, file, or decision."
                ],
                "max_results": [
                    "type": "integer",
                    "description": "Maximum results to return (1-10, default 5)."
                ]
            ],
            "required": ["query"]
        ]
    }

    let vectorStoreService: VectorStoreService?
    private let embedder: (any MemoryEmbeddingGenerating)?

    init(
        vectorStoreService: VectorStoreService?,
        embedder: (any MemoryEmbeddingGenerating)? = nil
    ) {
        self.vectorStoreService = vectorStoreService
        self.embedder = embedder
    }

    func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        guard let query = raw["query"] as? String else {
            return "Missing query."
        }
        let maxResults = min(10, max(1, raw["max_results"] as? Int ?? 5))
        let context = ToolInvocationContext.from(arguments: raw)
        let conversationId = context.conversationId

        // Session orientation summary — helps the model reorient without manual re-reads
        var orientationLines: [String] = []

        if let conversationId {
            let planMarkdown = await ConversationPlanStore.shared.get(conversationId: conversationId)
            if let planMarkdown {
                let progress = PlanChecklistTracker.progress(in: planMarkdown)
                if progress.total > 0 {
                    orientationLines.append("  plan tasks: \(progress.completed)/\(progress.total) complete")
                }
            }

            let readPaths = await ToolFileAccessLedger.shared.readPaths(conversationId: conversationId)
            if !readPaths.isEmpty {
                orientationLines.append("  files read this session: \(readPaths.count) file(s)")
                // Only list paths if reasonably few
                if readPaths.count <= 10 {
                    orientationLines.append("  paths:")
                    for path in readPaths {
                        orientationLines.append("    - \(path)")
                    }
                }
            }
        }

        let orientationSection = orientationLines.isEmpty ? "" : """
        session context:
        \(orientationLines.joined(separator: "\n"))

        ---
        """

        guard let vectorStoreService else {
            return orientationSection.isEmpty ? "Knowledge store not available." : orientationSection
        }
        guard let embedder else {
            return orientationSection.isEmpty ? "Embedding generator not available." : orientationSection
        }

        let results: [VectorSearchResult]
        do {
            results = try await vectorStoreService.searchByText(
                query: query,
                embeddingGenerator: { try await embedder.generateEmbedding(for: $0) },
                limit: maxResults
            )
        } catch {
            // Never mask retrieval failures as "no context" — the model must
            // know the store is degraded vs genuinely empty.
            return orientationSection + """
            status: error
            message: Retrieval failed: \(error.localizedDescription)
            content:
              items: []
            """
        }
        guard !results.isEmpty else {
            return orientationSection + """
            status: success
            message: No relevant context found for query.
            content:
              items: []
            """
        }

        var items: [String] = []
        for (index, entry) in results.prefix(maxResults).enumerated() {
            let source = entry.metadata?.source ?? "unknown"
            let text = entry.metadata?.text ?? ""
            // Entries are stored with category = conversationId (sourceReference
            // is never set on current write paths).
            let entryConvId = entry.metadata?.category
            let scopeLabel: String
            if let entryConvId, let conversationId, entryConvId == conversationId {
                scopeLabel = ""  // same session — no special label needed
            } else if entryConvId != nil {
                scopeLabel = " (prior session — use with caution)"
            } else {
                scopeLabel = ""
            }
            items.append("""
              - result \(index + 1):
                source: \(source)\(scopeLabel)
                text: \(text.prefix(500))
            """)
        }

        return orientationSection + """
        status: success
        message: Found \(results.count) relevant result(s).
        content:
          items:
        \(items.joined(separator: "\n"))
        """
    }
}
