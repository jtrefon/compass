import Foundation

// MARK: - Language

/// Supported languages for semantic chunking.
enum SemanticLanguage: String {
    case swift, php, javascript, typescript, python, ruby, go, rust, java, kotlin
    case markdown, text, unknown

    /// Block-start patterns for the language (function/class/struct boundaries).
    var blockStartPatterns: [String] {
        switch self {
        case .swift: return ["func ", "class ", "struct ", "enum ", "protocol ", "extension ", "init("]
        case .php: return ["function ", "class ", "public function", "private function", "protected function"]
        case .javascript, .typescript: return ["function ", "class ", "const ", "export function", "export class", "async function"]
        case .python: return ["def ", "class ", "async def "]
        case .ruby: return ["def ", "class ", "module "]
        case .go: return ["func ", "type ", "struct {"]
        case .rust: return ["fn ", "struct ", "enum ", "impl ", "trait "]
        case .java, .kotlin: return ["public ", "private ", "protected ", "class ", "void ", "fun "]
        case .markdown, .text, .unknown: return []
        }
    }
}

// MARK: - SemanticChunk

/// A semantic chunk of a tool result — a coherent block of code or text.
struct SemanticChunk: Sendable {
    let text: String
    let lineStart: Int
    let lineEnd: Int
}

// MARK: - SemanticChunker

/// Language-aware semantic chunking for tool results.
/// Splits at natural code boundaries (function/class/method) for code,
/// falls back to fixed-size windows for non-code content.
enum SemanticChunker {

    /// Split a tool result into semantic chunks.
    static func chunk(_ text: String, filePath: String? = nil) -> [SemanticChunk] {
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

    // MARK: - Language Detection

    static func detectLanguage(filePath: String?, content: String) -> SemanticLanguage {
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

    // MARK: - Code Structure Chunking

    /// Chunk by code structure: function/class/method boundaries.
    private static func chunkByCodeStructure(_ lines: [String], language: SemanticLanguage) -> [SemanticChunk] {
        let patterns = language.blockStartPatterns
        var chunks: [SemanticChunk] = []
        var currentStart = 0
        var currentLines: [String] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Start a new chunk at block boundaries (but not the first line)
            if index > 0 && patterns.contains(where: { trimmed.hasPrefix($0) }) {
                if !currentLines.isEmpty {
                    chunks.append(SemanticChunk(
                        text: currentLines.joined(separator: "\n"),
                        lineStart: currentStart + 1,
                        lineEnd: index
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
                lineStart: currentStart + 1,
                lineEnd: lines.count
            ))
        }

        return mergeTinyChunks(chunks, minLines: 3)
    }

    /// Chunk by fixed-size windows (for non-code content).
    private static func chunkByFixedSize(_ lines: [String], windowSize: Int) -> [SemanticChunk] {
        stride(from: 0, to: lines.count, by: windowSize).map { start in
            let end = min(start + windowSize, lines.count)
            return SemanticChunk(
                text: lines[start..<end].joined(separator: "\n"),
                lineStart: start + 1,
                lineEnd: end
            )
        }
    }

    /// Merge tiny chunks (< minLines) with the previous chunk.
    private static func mergeTinyChunks(_ chunks: [SemanticChunk], minLines: Int) -> [SemanticChunk] {
        guard chunks.count > 1 else { return chunks }
        var merged: [SemanticChunk] = []
        for chunk in chunks {
            let lineCount = chunk.lineEnd - chunk.lineStart + 1
            if lineCount < minLines, let last = merged.last {
                let combined = SemanticChunk(
                    text: last.text + "\n" + chunk.text,
                    lineStart: last.lineStart,
                    lineEnd: chunk.lineEnd
                )
                merged[merged.count - 1] = combined
            } else {
                merged.append(chunk)
            }
        }
        return merged
    }
}
