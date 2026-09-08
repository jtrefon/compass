import Foundation

/// NPU-powered semantic intelligence for Mission Control.
///
/// Runs entirely on the NeuralEngine via the embedding model — zero GPU/CPU
/// contention with the LLM. Actor for thread safety (matches VectorStoreService,
/// ConversationPlanStore patterns).
///
/// Capabilities:
/// 1. Extractive compression — selects most relevant code chunks from tool results
/// 2. Semantic deduplication — catches redundant notes
/// 3. Smart retrieval — scores evicted tool results for relevance during context resets
/// 4. Note clustering — organizes Mission Control rendering by semantic topic
/// 5. Information density scoring — metacognitive feedback on note quality
actor SemanticCompressor {

    private let embedder: any MemoryEmbeddingGenerating
    private let vectorStore: VectorStoreService?

    // Per-conversation key excerpts (updated as tool results are processed)
    private var keyExcerptsByConversation: [String: [KeyExcerpt]] = [:]

    // Embedding cache for notes (avoids re-embedding for dedup checks)
    private var noteEmbeddingCache: [String: [Float]] = [:]

    // Task context embedding cache (re-embedded when plan item changes)
    private var taskContextEmbedding: [Float]?
    private var lastTaskContext: String?

    init(embedder: any MemoryEmbeddingGenerating, vectorStore: VectorStoreService? = nil) {
        self.embedder = embedder
        self.vectorStore = vectorStore
    }

    // MARK: - Capability 1: Extractive Compression

    /// Process a tool result: split into chunks, score by relevance, select key excerpts,
    /// store full content in FAISS cold storage.
    func processToolResult(
        result: String,
        toolName: String,
        toolCallId: String,
        filePath: String?,
        taskContext: String,
        conversationId: String,
        topK: Int = 3
    ) async {
        let chunks = SemanticChunker.chunk(result, filePath: filePath)
        guard !chunks.isEmpty else { return }

        let taskEmbedding = await getTaskContextEmbedding(taskContext)

        var scored: [(chunk: SemanticChunk, score: Float)] = []
        for chunk in chunks {
            guard let embedding = try? await embedder.generateEmbedding(for: chunk.text) else { continue }
            let score = cosineSimilarity(embedding, taskEmbedding)
            scored.append((chunk, score))
        }

        let topExcerpts = scored
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { (chunk, score) in
                KeyExcerpt(
                    filePath: filePath ?? toolName,
                    lineStart: chunk.lineStart,
                    lineEnd: chunk.lineEnd,
                    text: chunk.text,
                    relevanceScore: score,
                    sourceToolCallId: toolCallId
                )
            }

        var current = keyExcerptsByConversation[conversationId] ?? []
        current.append(contentsOf: topExcerpts)
        current.sort { $0.relevanceScore > $1.relevanceScore }
        keyExcerptsByConversation[conversationId] = Array(current.prefix(10))

        // Store full content in FAISS (cold storage)
        if let vectorStore {
            for chunk in chunks {
                guard let embedding = try? await embedder.generateEmbedding(for: chunk.text) else { continue }
                try? await vectorStore.addEntry(
                    text: chunk.text,
                    vector: embedding,
                    source: filePath ?? toolName,
                    category: conversationId
                )
            }
        }
    }

    func currentKeyExcerpts(conversationId: String) -> [KeyExcerpt] {
        keyExcerptsByConversation[conversationId] ?? []
    }

    func clearKeyExcerpts(conversationId: String) {
        keyExcerptsByConversation[conversationId] = []
    }

    // MARK: - Capability 2: Semantic Deduplication

    /// Check if a new note is semantically redundant with existing notes.
    /// Returns the existing note text if duplicate (cosine sim > threshold).
    func findDuplicateNote(
        newNote: String,
        existingNotes: [String],
        threshold: Float = 0.85
    ) async -> String? {
        guard let newEmbedding = try? await embedder.generateEmbedding(for: newNote) else {
            return nil
        }

        for existing in existingNotes {
            let existingEmbedding: [Float]
            if let cached = noteEmbeddingCache[existing] {
                existingEmbedding = cached
            } else {
                guard let embedded = try? await embedder.generateEmbedding(for: existing) else { continue }
                noteEmbeddingCache[existing] = embedded
                existingEmbedding = embedded
            }

            let similarity = cosineSimilarity(newEmbedding, existingEmbedding)
            if similarity > threshold {
                return existing
            }
        }

        noteEmbeddingCache[newNote] = newEmbedding
        return nil
    }

    // MARK: - Capability 3: Smart Retrieval for Context Resets

    /// Score evicted tool results for relevance to current task.
    /// Used during context reset to decide what to re-inject.
    func scoreForRetrieval(
        taskContext: String,
        workingMemoryText: String,
        candidateCount: Int = 20
    ) async -> [(text: String, score: Float, source: String)] {
        let query = taskContext + "\n" + workingMemoryText
        guard let queryEmbedding = try? await embedder.generateEmbedding(for: query) else {
            return []
        }
        guard let vectorStore else { return [] }

        let results = (try? await vectorStore.search(queryVector: queryEmbedding, limit: candidateCount)) ?? []

        return results.compactMap { result in
            guard let text = result.metadata?.text, !text.isEmpty else { return nil }
            return (
                text: text,
                score: result.score,
                source: result.metadata?.source ?? "unknown"
            )
        }
    }

    // MARK: - Capability 4: Note Clustering

    /// Cluster notes by semantic similarity for organized rendering.
    /// Returns notes grouped by cluster label.
    func clusterNotes(
        _ notes: [WorkingMemoryNote]
    ) async -> [(label: String, notes: [WorkingMemoryNote])] {
        guard notes.count > 3 else {
            let grouped = Dictionary(grouping: notes) { $0.section }
            return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }

        var embeddings: [(note: WorkingMemoryNote, embedding: [Float])] = []
        for note in notes {
            if let embedding = try? await embedder.generateEmbedding(for: note.content) {
                embeddings.append((note, embedding))
            }
        }

        let sectionGroups = Dictionary(grouping: embeddings) { $0.note.section }
        let sectionNames = Array(sectionGroups.keys)
        var merged: Set<String> = []
        var clusters: [(label: String, notes: [WorkingMemoryNote])] = []

        for section in sectionNames.sorted() {
            if merged.contains(section) { continue }
            var clusterNotes = sectionGroups[section]?.map(\.note) ?? []
            merged.insert(section)

            for otherSection in sectionNames where !merged.contains(otherSection) && otherSection != section {
                let avgSim = averageCrossSimilarity(
                    sectionGroups[section] ?? [],
                    sectionGroups[otherSection] ?? []
                )
                if avgSim > 0.7 {
                    clusterNotes.append(contentsOf: sectionGroups[otherSection]?.map(\.note) ?? [])
                    merged.insert(otherSection)
                }
            }

            clusters.append((section, clusterNotes))
        }

        return clusters
    }

    // MARK: - Capability 5: Information Density Scoring

    /// Compute information density of working memory notes.
    /// High density = diverse, non-redundant findings. Low density = repetitive.
    func informationDensity(_ notes: [WorkingMemoryNote]) async -> Float {
        guard notes.count > 1 else { return 1.0 }

        var embeddings: [[Float]] = []
        for note in notes {
            if let embedding = try? await embedder.generateEmbedding(for: note.content) {
                embeddings.append(embedding)
            }
        }
        guard embeddings.count > 1 else { return 1.0 }

        var totalSimilarity: Float = 0
        var pairCount: Float = 0
        for i in 0..<embeddings.count {
            for j in (i+1)..<embeddings.count {
                totalSimilarity += cosineSimilarity(embeddings[i], embeddings[j])
                pairCount += 1
            }
        }
        let avgSimilarity = pairCount > 0 ? totalSimilarity / pairCount : 0
        return 1.0 - avgSimilarity
    }

    // MARK: - Private Helpers

    private func getTaskContextEmbedding(_ taskContext: String) async -> [Float] {
        if lastTaskContext == taskContext, let cached = taskContextEmbedding {
            return cached
        }
        let embedding = (try? await embedder.generateEmbedding(for: taskContext)) ?? []
        taskContextEmbedding = embedding
        lastTaskContext = taskContext
        return embedding
    }

    private func averageCrossSimilarity(
        _ groupA: [(note: WorkingMemoryNote, embedding: [Float])],
        _ groupB: [(note: WorkingMemoryNote, embedding: [Float])]
    ) -> Float {
        guard !groupA.isEmpty, !groupB.isEmpty else { return 0 }
        var total: Float = 0
        var count: Float = 0
        for a in groupA {
            for b in groupB {
                total += cosineSimilarity(a.embedding, b.embedding)
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
