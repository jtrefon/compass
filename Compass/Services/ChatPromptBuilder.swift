//
//  ChatPromptBuilder.swift
//  Compass
//
//  Created by Cascade on 02/01/2026.
//

import Foundation

/// Responsible for constructing and formatting prompts for the AI service.
class ChatPromptBuilder {
    /// Splits reasoning from the raw AI response text.
    /// - Parameter text: The raw response text.
    /// - Returns: A tuple containing the reasoning string (if found) and the cleaned content.
    static func splitReasoning(from text: String) -> (reasoning: String?, content: String) {
        guard !text.isEmpty else { return (nil, "") }

        if let tagged = splitTaggedReasoning(from: text) {
            return tagged
        }

        if let plain = splitPlainReasoning(from: text) {
            return plain
        }

        return (nil, text)
    }

    /// Sanitizes model text for user-visible rendering:
    /// strips reasoning from rendered content while preserving paragraph breaks.
    static func contentForDisplay(from text: String) -> String {
        let split = splitReasoning(from: text)
        let withoutToolMarkup = ToolMarkupStripper.stripMarkup(from: split.content)
        return normalizeDisplayWhitespace(withoutToolMarkup)
    }

    static func reasoningForDisplay(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var output = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let sectionLabels = [
            "Codebase Review & Insights",
            "Architecture:",
            "UI Layer:",
            "Routing:",
            "Strengths:",
            "Potential Issues:",
            "Recommendations:",
            "Remaining Work:",
            "Status:",
            "Reflection:",
            "Planning:",
            "Continuity:",
            "Analyze:",
            "Research:",
            "Plan:",
            "Reflect:",
            "Action:",
            "Delivery:"
        ]

        for label in sectionLabels {
            let escaped = NSRegularExpression.escapedPattern(for: label)
            let pattern = #"(?<!^)(?<!\n)(\s*)\#(escaped)"#
            output = output.replacingOccurrences(
                of: pattern,
                with: "\n\n\(label)",
                options: .regularExpression
            )
        }

        output = output.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeDisplayWhitespace(_ text: String) -> String {
        // Only strip leading/trailing whitespace — preserve all internal
        // spacing and newlines as the model intended.
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitPlainReasoning(from text: String) -> (reasoning: String?, content: String)? {
        let pattern = #"(?s)^\s*(Reflection:\s*.*?\n\s*Continuity:.*?)(?:\n{1,2}|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              let reasoningRange = Range(match.range(at: 1), in: text),
              let removeRange = Range(match.range(at: 0), in: text) else {
            return nil
        }

        let reasoning = String(text[reasoningRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var remaining = text
        remaining.removeSubrange(removeRange)
        let cleaned = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return reasoning.isEmpty ? nil : (reasoning, cleaned)
    }

    private static func splitTaggedReasoning(from text: String) -> (reasoning: String?, content: String)? {
        // Gemma 4 channel-based reasoning: <|channel>thought\n...<channel|>
        // (id 100 soc_token opens, id 101 eoc_token closes)
        // The word "thought" + newline after the opening tag are literal.
        // Everything after <channel|> is content (no separate response tag).
        for prefix in ["<|channel>thought\n", "<|channel>thought"] {
            guard let open = text.range(of: prefix, options: [.caseInsensitive]) else { continue }
            let afterOpen = text[open.upperBound...]
            guard let close = afterOpen.range(of: "<channel|>") else { continue }
            let reasoning = String(afterOpen[..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remaining = String(text[close.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning.isEmpty ? nil : reasoning, remaining)
        }

        // Legacy: <|channel|>thought...<|channel|>response (both sides pipe, old format)
        if let gemmaThought = text.range(of: "<|channel|>thought", options: [.caseInsensitive]),
           let gemmaResponse = text.range(of: "<|channel|>response", options: [.caseInsensitive]),
           gemmaThought.upperBound < gemmaResponse.lowerBound {
            let reasoning = String(text[gemmaThought.upperBound..<gemmaResponse.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(text[gemmaResponse.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning.isEmpty ? nil : reasoning, content)
        }

        let tags = [
            ("<thinking>", "</thinking>"),
            ("<think>", "</think>"),
            ("<thought>", "</thought>"),
            ("<ide_reasoning>", "</ide_reasoning>")
        ]

        for (openingTag, closingTag) in tags {
            guard let openingRange = text.range(of: openingTag, options: [.caseInsensitive]) else {
                continue
            }

            let contentBeforeTag = String(text[..<openingRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let afterOpeningTag = text[openingRange.upperBound...]

            if let closingRange = afterOpeningTag.range(of: closingTag, options: [.caseInsensitive]) {
                let reasoning = String(afterOpeningTag[..<closingRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let contentAfterTag = String(afterOpeningTag[closingRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = [contentBeforeTag, contentAfterTag]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return reasoning.isEmpty ? nil : (reasoning, cleaned)
            }

            let reasoning = String(afterOpeningTag)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return reasoning.isEmpty ? nil : (reasoning, contentBeforeTag)
        }

        for (_, closingTag) in tags {
            guard let closingRange = text.range(of: closingTag, options: [.caseInsensitive]) else {
                continue
            }

            let reasoning = String(text[..<closingRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(text[closingRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !reasoning.isEmpty {
                return (reasoning, content)
            }
        }

        return nil
    }
}
