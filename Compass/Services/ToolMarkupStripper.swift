import Foundation

/// Strips provider tool-call markup from model text at the commit boundary.
///
/// **Design rationale (why this is not a flat pile of regexes):**
/// - Each known markup shape lives in its own format struct with a *precise,
///   syntax-anchored* removal routine whose invariant is: identity on any
///   text that does not contain that exact markup shape. The golden tests
///   pin this — legitimate prose/code (`print("hello")`, `parse(config)`,
///   markdown tables) passes through byte-identical.
/// - Closed code fences are protected: models quote markup inside ``` blocks
///   when explaining, and those quotes are content. An UNCLOSED fence tail is
///   treated as strippable — anti-leakage outranks sample preservation for
///   truncated output.
/// - The pipe-envelope format cross-checks names against `ToolTaxonomy`
///   (single source of truth, Rule 3), making false positives effectively
///   impossible.
///
/// Public API unchanged: `containsToolCallMarkup`, `stripMarkup(from:)`,
/// `assistantContent(_:toolCalls:)`.
enum ToolMarkupStripper {
    /// Indicator substrings that a response carries tool-call markup even
    /// when the structured parser recovered zero calls. Single source of
    /// truth for the "malformed tool call" retry decision.
    static func containsToolCallMarkup(_ content: String) -> Bool {
        let indicators = [
            "<|tool_call>", "<tool_call>", "<tool_code>",
            "<invoke ", "<tool name=", "<function=", "<minimax:tool_call>",
        ]
        if indicators.contains(where: { content.contains($0) }) { return true }
        return content.range(of: #"call:[a-zA-Z_][a-zA-Z0-9_]*\s*\{"#, options: .regularExpression) != nil
    }

    static func stripMarkup(from content: String) -> String {
        guard !content.isEmpty else { return content }

        // Whole-block formats first: a ```tool fence is markup by definition.
        var output = FencedToolBlockStripper.strip(from: content)

        // Everything else runs only outside protected (closed) fences.
        output = CodeFencePartitioner.applyOutsideProtectedFences(output) { segment in
            var s = GemmaToolCallStripper.strip(from: segment)
            s = SpecialTokenMarkerStripper.strip(from: s)
            s = XMLTagMarkupStripper.strip(from: s)
            s = PipeEnvelopeStripper.strip(from: s)
            s = LeadingJSONEnvelopeStripper.strip(from: s)
            return s
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Content for a committed assistant message that carries tool calls:
    /// markup is stripped so the visible message and the next request never
    /// see raw `<|tool_call>call:...{...}` (or any provider's tool markup).
    /// Provider-agnostic — applied at the commit boundary, not inside any
    /// inference engine.
    static func assistantContent(_ content: String?, toolCalls: [AIToolCall]?) -> String {
        guard let content else { return "" }
        guard !(toolCalls?.isEmpty ?? true) else { return content }
        return stripMarkup(from: content)
    }
}

// MARK: - Fence awareness

/// Splits text into protected (closed ``` fence) and plain segments.
enum CodeFencePartitioner {
    /// Applies `transform` to every non-protected segment, joining results.
    /// A fence is protected only when its closing delimiter exists; an
    /// unterminated opening fence leaves the tail strippable (truncated
    /// output must still be cleaned).
    static func applyOutsideProtectedFences(
        _ content: String,
        _ transform: (String) -> String
    ) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var plainBuffer: [String] = []
        var fenceBuffer: [String]?
        var fenceDelimiterCount = 0

        func flushPlain() {
            guard !plainBuffer.isEmpty else { return }
            result.append(transform(plainBuffer.joined(separator: "\n")))
            plainBuffer.removeAll()
        }
        func flushFence() {
            guard var buffer = fenceBuffer else { return }
            if fenceDelimiterCount >= 2 {
                // Closed fence — protected verbatim.
                result.append(buffer.joined(separator: "\n"))
            } else {
                // Unterminated fence — tail is strippable.
                flushPlainIfNeeded(&buffer)
            }
            fenceBuffer = nil
        }
        func flushPlainIfNeeded(_ buffer: inout [String]) {
            guard !buffer.isEmpty else { return }
            result.append(transform(buffer.joined(separator: "\n")))
            buffer.removeAll()
        }

        for line in lines {
            if fenceBuffer != nil {
                fenceBuffer?.append(line)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    fenceDelimiterCount += 1
                    flushFence()
                }
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushPlain()
                fenceBuffer = [line]
                fenceDelimiterCount = 1
            } else {
                plainBuffer.append(line)
            }
        }
        flushFence()
        flushPlain()
        return result.joined(separator: "\n")
    }
}

// MARK: - Format 1: ```tool fenced block

/// Removes entire ```tool … ``` regions (the model wrapped a tool call in a
/// labelled fence instead of using structured calls).
enum FencedToolBlockStripper {
    private static let pattern = #"(?is)```tool\s*\n.*?\n```"#

    static func strip(from content: String) -> String {
        content.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

// MARK: - Format 2: Gemma <|tool_call>call:name{…}

/// Gemma format: `<|tool_call>call:name{args}</|tool_call>` plus the `<|"|>`
/// string delimiters. Brace balancing cannot be expressed as a regex, so the
/// `call:name{...}` regions are removed with a balanced scan.
enum GemmaToolCallStripper {
    static func strip(from content: String) -> String {
        var output = content
        output = output.replacingOccurrences(of: "<|tool_call>", with: "")
        output = output.replacingOccurrences(of: "</|tool_call>", with: "")
        output = output.replacingOccurrences(of: "<|tool_call|>", with: "")

        let marker = "call:"
        var result = ""
        var searchStart = output.startIndex
        while let markerRange = output.range(of: marker, range: searchStart..<output.endIndex) {
            let afterMarker = markerRange.upperBound
            var nameEnd = afterMarker
            while nameEnd < output.endIndex,
                  output[nameEnd].isLetter || output[nameEnd].isNumber || output[nameEnd] == "_" {
                nameEnd = output.index(after: nameEnd)
            }
            var braceStart = nameEnd
            while braceStart < output.endIndex, output[braceStart].isWhitespace {
                braceStart = output.index(after: braceStart)
            }
            guard braceStart < output.endIndex, output[braceStart] == "{" else {
                result += String(output[searchStart..<markerRange.upperBound])
                searchStart = markerRange.upperBound
                continue
            }
            if let closeIndex = Self.balancedBraceClose(in: output, openAt: braceStart) {
                result += String(output[searchStart..<markerRange.lowerBound])
                searchStart = output.index(after: closeIndex)
            } else {
                // Unbalanced (truncated call): keep scanning past this marker;
                // malformed-call detection upstream handles the retry.
                result += String(output[searchStart..<markerRange.upperBound])
                searchStart = markerRange.upperBound
            }
        }
        result += String(output[searchStart...])

        result = result.replacingOccurrences(of: "<|\"|>", with: "\"")
        result = result.replacingOccurrences(of: "<|\"|", with: "\"")
        return result
    }

    /// Index of the `}` matching the `{` at `openAt`, or nil if unbalanced.
    private static func balancedBraceClose(in text: String, openAt: String.Index) -> String.Index? {
        var depth = 1
        var pos = text.index(after: openAt)
        while pos < text.endIndex, depth > 0 {
            let ch = text[pos]
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1 }
            if depth > 0 { pos = text.index(after: pos) }
        }
        return depth == 0 ? pos : nil
    }
}

// MARK: - Format 3: special-token channel/turn markers

/// Exact-literal special tokens emitted around tool turns by some local
/// engines. Literal-only — cannot appear in legitimate prose/code.
enum SpecialTokenMarkerStripper {
    private static let literals = [
        "<|channel>", "<channel|>",
        "<|tool>", "<tool|>",
        "<|tool_response>", "<tool_response|>",
        "<|turn>", "<turn|>",
        "<|think|>",
    ]
    private static let pairedPattern = #"(?is)<\|tool_calls\|>.*?</\|tool_calls\|>"#
    private static let functionCallPattern = #"(?is)<start_function_call>\s*.*?\s*<end_function_call>"#

    static func strip(from content: String) -> String {
        var output = content
        for literal in literals {
            output = output.replacingOccurrences(of: literal, with: "")
        }
        output = output.replacingOccurrences(of: pairedPattern, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: functionCallPattern, with: "", options: .regularExpression)
        return output
    }
}

// MARK: - Format 4: XML tag families

/// Paired XML-style tool markup across providers, plus orphan open/close
/// fragments left by truncation. Tag names are specific — none occur in
/// ordinary prose outside quoted samples (which fences now protect).
enum XMLTagMarkupStripper {
    private static let regionPatterns = [
        #"(?is)<tool_call>\s*.*?\s*</tool_call>"#,
        #"(?is)<tool_code>\s*.*?\s*</tool_code>"#,
        #"(?is)<minimax:tool_call>\s*.*?\s*</minimax:tool_call>"#,
        #"(?is)<invoke\s+name=\"[^\"]+\"\s*>.*?</invoke>"#,
        #"(?is)<tool\s+name=\"[^\"]+\"\s*>.*?</tool>"#,
        #"(?is)<arg_key>\s*.*?\s*</arg_key>"#,
        #"(?is)<arg_value>\s*.*?\s*</arg_value>"#,
        #"(?is)<start_function_call>\s*.*?\s*<end_function_call>"#,
    ]

    private static let orphanTagPatterns = [
        #"</?tool_call[^>]*>"#,
        #"</?tool_code[^>]*>"#,
        #"</?invoke[^>]*>"#,
        #"</?tool[^>]*>"#,
        #"</?arg\s+name=\"[^\"]+\">"#,
        #"</?parameter\s+name=\"[^\"]+\">"#,
        #"</?param\s+name=\"[^\"]+\">"#,
    ]

    private static let assignmentTagPatterns = [
        #"(?is)<function=[^\s>]+>\s*|</function>"#,
        #"(?is)<parameter=[^\s>]+>\s*|</parameter>"#,
    ]

    static func strip(from content: String) -> String {
        var output = content
        for pattern in regionPatterns {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        for pattern in orphanTagPatterns {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        for pattern in assignmentTagPatterns {
            output = output.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return output
    }
}

// MARK: - Format 5: pipe envelope `tool_name|{json}`

/// Line-anchored `name|{json}` / `name|[json]` envelopes. Two guards make
/// false positives effectively impossible:
/// 1. Line-start anchor + immediately-following bracket (balanced).
/// 2. The name must be a canonical tool name from `ToolTaxonomy`.
enum PipeEnvelopeStripper {
    private static let knownTools = ToolTaxonomy.execution

    static func strip(from content: String) -> String {
        guard content.contains("|") else { return content }

        let lines = content.components(separatedBy: "\n")
        var result: [String] = []

        for line in lines {
            if let range = envelopeRange(in: line) {
                result.append(String(line[..<range.lowerBound]))
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }

    /// Range of `name|{…}` within one line when it is genuine tool markup.
    private static func envelopeRange(in line: String) -> ClosedRange<String.Index>? {
        guard let match = line.range(
            of: #"^\s*([a-z_][a-z0-9_]*)\s*\|"#,
            options: .regularExpression
        ) else { return nil }

        guard let name = extractName(from: line[match]) else { return nil }
        let canonical = knownTools.contains(name) || ParserHelper.normalizeName(name) != name
        guard canonical else { return nil }

        // Bracket must follow the pipe directly (whitespace tolerated).
        var cursor = match.upperBound
        while cursor < line.endIndex, line[cursor] == " " { cursor = line.index(after: cursor) }
        guard cursor < line.endIndex else { return nil }
        let opener = line[cursor]
        guard opener == "{" || opener == "[" else { return nil }
        let closer: Character = opener == "{" ? "}" : "]"

        var depth = 0
        while cursor < line.endIndex {
            let ch = line[cursor]
            if ch == opener { depth += 1 }
            else if ch == closer {
                depth -= 1
                if depth == 0 { return match.lowerBound...cursor }
            }
            cursor = line.index(after: cursor)
        }
        return nil
    }

    private static func extractName(from prefix: Substring) -> String? {
        guard let pipeIndex = prefix.firstIndex(of: "|") else { return nil }
        let name = prefix[..<pipeIndex].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Format 6: leading bare JSON envelope

/// Some models emit a bare JSON object (`{"tool_calls": …}` or
/// `{"name": …, …}`) at the very start of otherwise plain content instead of
/// using structured calls. Removed only when the object is balanced — a
/// truncated envelope is left for malformed-call handling upstream rather
/// than being half-eaten silently.
enum LeadingJSONEnvelopeStripper {
    static func strip(from content: String) -> String {
        let patterns = [
            #"^\s*\{\s*"tool_calls"\s*:"#,
            #"^\s*\{\s*"name"\s*:"#,
        ]
        for pattern in patterns {
            guard let match = content.range(of: pattern, options: .regularExpression),
                  let openBrace = content.range(of: "{", range: match) else { continue }
            if let close = balancedObjectClose(in: content, from: openBrace.lowerBound) {
                return String(content[close...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return content
    }

    /// Index of the character AFTER the `}` matching the `{` at `openAt`.
    private static func balancedObjectClose(in text: String, from openAt: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var pos = openAt
        while pos < text.endIndex {
            let ch = text[pos]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return text.index(after: pos) }
                }
            }
            pos = text.index(after: pos)
        }
        return nil
    }
}
