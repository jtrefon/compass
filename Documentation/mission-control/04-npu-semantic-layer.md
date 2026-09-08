# 04 — NPU Semantic Intelligence Layer

> Part of: [Mission Control Spec](00-overview.md)

---

## 1. Overview

The existing `bge-small-en-v1.5` embedding model (CoreML, running on NeuralEngine via `.cpuAndNeuralEngine`) is elevated from passive embedding generation to an active semantic intelligence layer. It runs **in parallel** with LLM generation on the GPU — zero context tokens consumed, zero GPU/CPU contention.

### What the NPU CAN do

- Generate 384-dimensional embeddings for text (~5ms per chunk on NeuralEngine)
- Compute cosine similarity between vectors
- Support FAISS retrieval (already integrated)

### What the NPU CANNOT do

- Generate text (no decoder head, no token sampling)
- Summarize content (that's generative, not embedding)
- Understand code semantics at a deep level (it's a general text encoder)

### The key insight

We don't need generative summarization. We need **extractive compression** — selecting the most relevant parts of a tool result, not paraphrasing them. This is exactly what embeddings enable: score chunks by relevance to the current task, keep the top-K, discard the rest. The model's own notes handle the generative summarization layer.

---

## 2. SemanticCompressor Specification

### 2.1 The Actor

```swift
/// NPU-powered semantic intelligence for Mission Control.
/// Runs entirely on the NeuralEngine — zero GPU/CPU contention with the LLM.
/// Actor for thread safety (matches VectorStoreService, ConversationLogStore).
actor SemanticCompressor {
    
    private let embedder: MemoryEmbeddingGenerating
    private let vectorStore: VectorStoreService?
    
    // Per-conversation key excerpts (updated as tool results are processed)
    private var keyExcerptsByConversation: [String: [KeyExcerpt]] = [:]
    
    // Embedding cache for notes (avoids re-embedding for dedup checks)
    private var noteEmbeddingCache: [String: [Float]] = [:]  // noteId → embedding
    
    // Task context embedding cache (re-embedded when plan item changes)
    private var taskContextEmbedding: [Float]?
    private var lastTaskContext: String?
    
    init(embedder: MemoryEmbeddingGenerating, vectorStore: VectorStoreService?) {
        self.embedder = embedder
        self.vectorStore = vectorStore
    }
    
    // Methods documented in sections below
}
```

### 2.2 Data Structures

```swift
/// A line range within a file.
struct LineRange: Codable, Sendable, Hashable {
    let start: Int
    let end: Int
    var description: String { "\(start)-\(end)" }
}

/// A key excerpt selected by the NPU from a tool result.
struct KeyExcerpt: Codable, Sendable {
    let id: String
    let filePath: String           // source file (if known from tool result)
    let lineRange: LineRange       // line range in the source
    let text: String               // the actual code/text excerpt
    let relevanceScore: Float      // cosine similarity to task context (0-1)
    let sourceToolCallId: String   // which tool result this came from
    let timestamp: Date
}

/// A semantic chunk of a tool result.
struct SemanticChunk: Sendable {
    let text: String
    let lineRange: LineRange
    let startChar: Int
}
```

---

## 3. Capability 1: Extractive Compression

### 3.1 The Problem

A `read` tool result might be 50 lines (1.5K tokens). For a security audit, 5 of those lines are critical (the hardcoded key, the missing validation). The other 45 are boilerplate (namespace, imports, closing braces). The model needs the 5 critical lines; the 45 are context noise.

### 3.2 The Solution

```
1. Split tool result into semantic chunks (by function/class/block)
2. Embed each chunk (NPU, ~5ms per chunk)
3. Embed current task context (NPU, ~5ms)
4. Score each chunk by cosine similarity to task context
5. Keep top-K relevant chunks as Key Excerpts
6. Store ALL chunks in FAISS cold storage with embeddings
```

### 3.3 Implementation

```swift
extension SemanticCompressor {
    
    /// Process a tool result: split into chunks, score by relevance, select key excerpts,
    /// store full content in FAISS.
    func processToolResult(
        result: String,
        toolName: String,
        toolCallId: String,
        filePath: String?,
        taskContext: String,
        conversationId: String,
        topK: Int = 3
    ) async {
        // 1. Split into semantic chunks
        let chunks = splitIntoSemanticChunks(result, filePath: filePath)
        guard !chunks.isEmpty else { return }
        
        // 2. Get task context embedding (cached)
        let taskEmbedding = await getTaskContextEmbedding(taskContext)
        
        // 3. Score each chunk
        var scored: [(chunk: SemanticChunk, score: Float)] = []
        for chunk in chunks {
            let embedding = try? await embedder.generateEmbedding(for: chunk.text)
            guard let embedding else { continue }
            let score = cosineSimilarity(embedding, taskEmbedding)
            scored.append((chunk, score))
        }
        
        // 4. Select top-K
        let topExcerpts = scored
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { (chunk, score) in
                KeyExcerpt(
                    id: UUID().uuidString,
                    filePath: filePath ?? "unknown",
                    lineRange: chunk.lineRange,
                    text: chunk.text,
                    relevanceScore: score,
                    sourceToolCallId: toolCallId,
                    timestamp: Date()
                )
            }
        
        // 5. Update key excerpts for this conversation
        var current = keyExcerptsByConversation[conversationId] ?? []
        current.append(contentsOf: topExcerpts)
        // Keep only top 10 excerpts overall (by score)
        current.sort { $0.relevanceScore > $1.relevanceScore }
        keyExcerptsByConversation[conversationId] = Array(current.prefix(10))
        
        // 6. Store full content in FAISS (cold storage)
        if let vectorStore {
            for chunk in chunks {
                let embedding = try? await embedder.generateEmbedding(for: chunk.text)
                guard let embedding else { continue }
                try? await vectorStore.store(
                    vector: embedding,
                    metadata: SourceReference(
                        source: filePath ?? toolName,
                        text: chunk.text,
                        category: conversationId
                    )
                )
            }
        }
    }
    
    /// Get the current key excerpts for a conversation (for Mission Control rendering).
    func currentKeyExcerpts(conversationId: String) -> [KeyExcerpt] {
        keyExcerptsByConversation[conversationId] ?? []
    }
    
    /// Clear key excerpts for a conversation (after controlled reset).
    func clearKeyExcerpts(conversationId: String) {
        keyExcerptsByConversation[conversationId] = []
    }
}
```

### 3.4 Semantic Chunking

The chunking strategy is language-aware — it splits at natural code boundaries:

```swift
extension SemanticCompressor {
    
    /// Split a tool result into semantic chunks.
    /// Language-aware: splits at function/class/block boundaries.
    /// Falls back to 10-line windows for non-code content.
    private func splitIntoSemanticChunks(_ text: String, filePath: String?) -> [SemanticChunk] {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return [] }
        
        let language = detectLanguage(filePath: filePath, content: text)
        
        switch language {
        case .swift, .php, .javascript, .typescript, .python, .ruby, .go, .rust, .java, .kotlin:
            return chunkByCodeStructure(lines, language: language)
        case .markdown, .text, .unknown:
            return chunkByFixedSize(lines, windowSize: 10)
        }
    }
    
    /// Chunk by code structure: function/class/method boundaries.
    /// Detects: `func `, `function `, `class `, `public `, `private `, `def `, etc.
    private func chunkByCodeStructure(_ lines: [String], language: Language) -> [SemanticChunk] {
        var chunks: [SemanticChunk] = []
        var currentStart = 0
        var currentLines: [String] = []
        
        let blockStartPatterns: [String]
        switch language {
        case .swift: blockStartPatterns = ["func ", "class ", "struct ", "enum ", "protocol ", "extension ", "init("]
        case .php: blockStartPatterns = ["function ", "class ", "public function", "private function", "protected function"]
        case .javascript, .typescript: blockStartPatterns = ["function ", "class ", "const ", "export function", "export class", "async function"]
        case .python: blockStartPatterns = ["def ", "class ", "async def "]
        case .ruby: blockStartPatterns = ["def ", "class ", "module "]
        case .go: blockStartPatterns = ["func ", "type ", "struct {"]
        case .rust: blockStartPatterns = ["fn ", "struct ", "enum ", "impl ", "trait "]
        case .java, .kotlin: blockStartPatterns = ["public ", "private ", "protected ", "class ", "void ", "fun "]
        default: blockStartPatterns = ["function ", "class ", "def "]
        }
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Start a new chunk at block boundaries (but not the first line)
            if index > 0 && blockStartPatterns.contains(where: { trimmed.hasPrefix($0) }) {
                if !currentLines.isEmpty {
                    chunks.append(SemanticChunk(
                        text: currentLines.joined(separator: "\n"),
                        lineRange: LineRange(start: currentStart + 1, end: index),
                        startChar: 0  // simplified
                    ))
                }
                currentStart = index
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }
        
        // Don't forget the last chunk
        if !currentLines.isEmpty {
            chunks.append(SemanticChunk(
                text: currentLines.joined(separator: "\n"),
                lineRange: LineRange(start: currentStart + 1, end: lines.count),
                startChar: 0
            ))
        }
        
        // Merge tiny chunks (< 3 lines) with the previous chunk
        return mergeTinyChunks(chunks, minLines: 3)
    }
    
    /// Chunk by fixed-size windows (for non-code content).
    private func chunkByFixedSize(_ lines: [String], windowSize: Int) -> [SemanticChunk] {
        stride(from: 0, to: lines.count, by: windowSize).map { start in
            let end = min(start + windowSize, lines.count)
            return SemanticChunk(
                text: lines[start..<end].joined(separator: "\n"),
                lineRange: LineRange(start: start + 1, end: end),
                startChar: 0
            )
        }
    }
}
```

### 3.5 Language Detection

```swift
private enum Language: String {
    case swift, php, javascript, typescript, python, ruby, go, rust, java, kotlin
    case markdown, text, unknown
}

private func detectLanguage(filePath: String?, content: String) -> Language {
    if let filePath {
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .swift
        case "php": return .php
        case "js", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "py": return .python
        case "rb": return .ruby
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "md", "markdown": return .markdown
        case "txt": return .text
        default: break
        }
    }
    // Content-based fallback
    if content.contains("<?php") { return .php }
    if content.contains("import SwiftUI") { return .swift }
    if content.contains("#!/usr/bin/python") || content.contains("def ") { return .python }
    return .unknown
}
```

---

## 4. Capability 2: Semantic Deduplication

### 4.1 The Problem

After a context reset, the model might re-read a file and write a note that duplicates an existing note. Without dedup, working memory fills with redundant findings.

### 4.2 The Solution

When `NoteTool` receives a new note, it asks `SemanticCompressor` to check for duplicates:

```swift
extension SemanticCompressor {
    
    /// Check if a new note is semantically redundant with existing notes.
    /// Returns the existing note text if duplicate (cosine sim > threshold).
    func findDuplicateNote(
        newNote: String,
        existingNotes: [String],
        threshold: Float = 0.85
    ) async -> String? {
        let newEmbedding = try? await embedder.generateEmbedding(for: newNote)
        guard let newEmbedding else { return nil }
        
        for existing in existingNotes {
            // Use cached embedding if available
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
        
        // Cache the new note's embedding for future checks
        noteEmbeddingCache[newNote] = newEmbedding
        return nil
    }
}
```

### 4.3 Threshold Tuning

- `0.85` — conservative (only catches near-exact duplicates)
- `0.75` — moderate (catches paraphrased duplicates)
- `0.65` — aggressive (might merge related-but-distinct findings)

Start at `0.85` to avoid false positives. The model can always `update` a section if it wants to merge related findings intentionally.

---

## 5. Capability 3: Smart Retrieval for Context Resets

### 5.1 The Problem

During a controlled reset, we need to decide which evicted tool results to re-inject into the fresh context. "Last 3-5 results" is a naive heuristic — the most relevant result might be from 10 turns ago.

### 5.2 The Solution

Score ALL evicted tool results (from FAISS) against the current task context + working memory:

```swift
extension SemanticCompressor {
    
    /// Score evicted tool results for relevance to current task.
    /// Used during context reset to decide what to re-inject.
    func scoreForRetrieval(
        taskContext: String,
        workingMemoryText: String,
        candidateCount: Int = 20
    ) async -> [(text: String, score: Float, source: String)] {
        // Combine task context + working memory as the query
        let query = taskContext + "\n" + workingMemoryText
        let queryEmbedding = try? await embedder.generateEmbedding(for: query)
        guard let queryEmbedding else { return [] }
        
        // Search FAISS for most relevant stored chunks
        guard let vectorStore else { return [] }
        
        let results = try? await vectorStore.search(
            vector: queryEmbedding,
            limit: candidateCount
        )
        
        return (results ?? []).map { result in
            (
                text: result.metadata?.text ?? "",
                score: result.score,
                source: result.metadata?.source ?? "unknown"
            )
        }
    }
}
```

### 5.3 What Gets Re-Injected After Reset

```
Controlled Reset fires:
  1. Build fresh context:
     [System Prompt — full]
     [Mission Control — goal, plan, notes, key excerpts, budget]
  
  2. Query FAISS for top-K relevant evicted chunks:
     query = currentPlanItem + workingMemoryText
     results = semanticCompressor.scoreForRetrieval(...)
  
  3. Re-inject top 3-5 results as a "retrieved context" user message:
     "## Retrieved Context (from previous exploration)
     [lib/PaymentService.php:8-11] $this->stripeKey = "sk_live_XXXXX";
     [lib/NotificationService.php:45-52] public function sendSMS($to, $message) { ... }
     ..."
  
  4. Re-inject edit_target reads (protected, always carried through)
  
  5. User message: "Continue from your notes. Context was reset to free space."
```

The model gets back the specific code chunks most relevant to what it's doing right now — not the last N results by chronology.

---

## 6. Capability 4: Note Clustering

### 6.1 The Problem

As notes accumulate, Mission Control's working memory section can become a flat list of unrelated findings. The model has to scan all of them to find what's relevant.

### 6.2 The Solution

Cluster notes by semantic similarity and render them grouped by topic:

```swift
extension SemanticCompressor {
    
    /// Cluster notes by semantic similarity for organized rendering.
    /// Returns notes grouped by cluster label.
    func clusterNotes(
        _ notes: [WorkingMemoryNote]
    ) async -> [(label: String, notes: [WorkingMemoryNote])] {
        guard notes.count > 3 else {
            // Too few to cluster — group by section name
            let grouped = Dictionary(grouping: notes) { $0.section }
            return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        
        // Embed all notes
        var embeddings: [(note: WorkingMemoryNote, embedding: [Float])] = []
        for note in notes {
            if let embedding = try? await embedder.generateEmbedding(for: note.content) {
                embeddings.append((note, embedding))
            }
        }
        
        // Simple clustering: group by section name, then merge sections with high cross-similarity
        var sectionGroups: [String: [(note: WorkingMemoryNote, embedding: [Float])]] = Dictionary(grouping: embeddings) { $0.note.section }
        
        // Merge similar sections
        let sectionNames = Array(sectionGroups.keys)
        var merged: Set<String> = []
        var clusters: [(label: String, notes: [WorkingMemoryNote])] = []
        
        for section in sectionNames {
            if merged.contains(section) { continue }
            var clusterNotes = sectionGroups[section]?.map { $0.note } ?? []
            merged.insert(section)
            
            // Check other sections for similarity
            for otherSection in sectionNames {
                if merged.contains(otherSection) || otherSection == section { continue }
                let avgSim = averageCrossSimilarity(
                    sectionGroups[section] ?? [],
                    sectionGroups[otherSection] ?? []
                )
                if avgSim > 0.7 {
                    clusterNotes.append(contentsOf: sectionGroups[otherSection]?.map { $0.note } ?? [])
                    merged.insert(otherSection)
                }
            }
            
            clusters.append((label: section, notes: clusterNotes))
        }
        
        return clusters
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
}
```

### 6.3 Rendered Output

```
### Working Memory

**Security Findings:**
- PaymentService: hardcoded Stripe key (CRITICAL)
- PaymentService: no amount validation (RISK)
- NotificationService: no SMS rate limiting (RISK)

**Architecture:**
- plugin-entry.php: 3 hooks, controller at L23
- Delegates to PaymentService + NotificationService
- REST base: /wp-json/plugin/v1/

**NotificationService:**
- wp_mail + Twilio SMS
- env var for key (good)
```

Sections with high cross-similarity (e.g., "risks" and "PaymentService" when PaymentService has risk findings) are merged under a semantic label.

---

## 7. Capability 5: Information Density Scoring

### 7.1 The Problem

The model might write 10 notes that are all saying the same thing in slightly different ways. Quantity ≠ quality.

### 7.2 The Solution

Measure the information density of working memory:

```swift
extension SemanticCompressor {
    
    /// Compute information density of working memory notes.
    /// High density = diverse, non-redundant findings.
    /// Low density = repetitive notes.
    func informationDensity(_ notes: [WorkingMemoryNote]) async -> Float {
        guard notes.count > 1 else { return 1.0 }
        
        // Embed all notes
        var embeddings: [[Float]] = []
        for note in notes {
            if let embedding = try? await embedder.generateEmbedding(for: note.content) {
                embeddings.append(embedding)
            }
        }
        guard embeddings.count > 1 else { return 1.0 }
        
        // Compute average pairwise similarity
        var totalSimilarity: Float = 0
        var pairCount: Float = 0
        for i in 0..<embeddings.count {
            for j in (i+1)..<embeddings.count {
                totalSimilarity += cosineSimilarity(embeddings[i], embeddings[j])
                pairCount += 1
            }
        }
        let avgSimilarity = pairCount > 0 ? totalSimilarity / pairCount : 0
        
        // Density = 1 - avgSimilarity (high similarity = low density)
        return 1.0 - avgSimilarity
    }
}
```

### 7.3 Mission Control Display

```
### Context Budget
22000 / 30000 tokens (73% used)
⚠️ Context nearly full. Your notes have what you need — stop exploring and start acting.

Working memory: 8 notes, 92% unique information.
You have good coverage — consider acting on your findings.
```

vs.

```
Working memory: 8 notes, 45% unique information.
Notes are repetitive — consolidate and explore new areas.
```

The model gets metacognitive feedback about the *quality* of its notes, not just the quantity.

---

## 8. NPU Performance Characteristics

| Operation | Latency (NeuralEngine) | Frequency | Total overhead per turn |
|---|---|---|---|
| Embed 1 chunk (~100 chars) | ~5ms | 5-10 chunks per tool result | ~25-50ms |
| Embed task context | ~5ms | 1 per turn (cached) | ~5ms |
| Cosine similarity (384-dim) | <1ms | 10-50 comparisons | <50ms |
| FAISS store (per chunk) | ~2ms | 5-10 per tool result | ~10-20ms |
| FAISS search (top-20) | ~5ms | 1 per reset | ~5ms |
| **Total per turn** | — | — | **~40-125ms** |

**LLM generation per turn: 2-3 seconds.** NPU overhead is 2-6% of generation time — effectively invisible. And it runs in parallel (detached task on utility queue), so it doesn't block the LLM at all.

---

## 9. Integration with Existing Vector Store

The `SemanticCompressor` uses the existing `VectorStoreService` (FAISS) for cold storage. No new vector store is created — we reuse the existing infrastructure:

| Existing | New usage |
|---|---|
| `VectorStoreService.store(vector:metadata:)` | Store tool result chunks |
| `VectorStoreService.searchByText(query:limit:)` | Smart retrieval during resets |
| `VectorStoreEmbeddingCoordinator` | Already buffers and stores — SemanticCompressor can delegate to it |
| `.ide/vector_store/` | Existing directory, no new storage path |
| `ContextTool` | Already retrieves from FAISS — model can use it for on-demand retrieval |

The `SemanticCompressor` is a new **producer** of FAISS entries (storing tool result chunks) and a new **consumer** (scoring for retrieval). The existing `ContextTool` remains the model's interface for on-demand retrieval.

---

## 10. When NPU Is Unavailable

If the embedding model fails to load (missing model file, CoreML error, etc.), the system degrades gracefully:

| Capability | With NPU | Without NPU (degraded) |
|---|---|---|
| Extractive compression | NPU selects top-K relevant chunks | All chunks kept (no compression) — tool results stay full |
| Semantic dedup | Catches redundant notes | No dedup — model might write duplicate notes |
| Smart retrieval | FAISS scores by relevance | Last-K results re-injected (naive heuristic) |
| Note clustering | Semantically grouped | Grouped by section name only |
| Information density | Quality score displayed | No quality score |

The `SemanticCompressor` checks `embedder` availability at init and falls back to no-op behavior if unavailable. The core Mission Control system (notes, plan, budget) works without the NPU — it's the intelligence layer that's degraded, not the foundation.
