import Foundation

/// Dynamically extensible registry of tool-call format parsers (Strategy pattern).
///
/// OCP: Add new model formats by creating a new `ToolCallFormatParser` and
/// registering it. No existing code changes needed.
/// Thread-safe via NSLock.
public final class ParserRegistry: @unchecked Sendable {
    private var parsers: [String: ToolCallFormatParser] = [:]
    /// Registration order — `allParsers()` must iterate deterministically:
    /// more specific formats (JSON/XML) must be tried before loose heuristics
    /// (tool-call blocks), otherwise a Dictionary's hash order decides which
    /// parser wins and the same text decodes differently per process.
    private var orderedIdentifiers: [String] = []
    private let lock = NSLock()

    public init() {
        // Empty by design — parsers are registered explicitly via register().
    }

    /// Register a parser for a specific format.
    public func register(_ parser: ToolCallFormatParser) {
        lock.lock()
        if parsers[parser.formatIdentifier] == nil {
            orderedIdentifiers.append(parser.formatIdentifier)
        }
        parsers[parser.formatIdentifier] = parser
        lock.unlock()
    }

    /// Retrieve a parser by its format identifier.
    public func parser(for identifier: String) -> ToolCallFormatParser? {
        lock.lock()
        defer { lock.unlock() }
        return parsers[identifier]
    }

    /// All currently registered parsers, in registration order.
    public func allParsers() -> [ToolCallFormatParser] {
        lock.lock()
        defer { lock.unlock() }
        return orderedIdentifiers.compactMap { parsers[$0] }
    }

    /// Remove a parser.
    public func unregister(_ parser: ToolCallFormatParser) {
        lock.lock()
        orderedIdentifiers.removeAll { $0 == parser.formatIdentifier }
        parsers.removeValue(forKey: parser.formatIdentifier)
        lock.unlock()
    }

    /// Remove all parsers.
    public func clear() {
        lock.lock()
        orderedIdentifiers.removeAll()
        parsers.removeAll()
        lock.unlock()
    }

    /// Iterate all registered parsers and return the first successful decode.
    public func decodeToolCalls(from content: String) -> [AIToolCall]? {
        let all = allParsers()
        for parser in all {
            let (calls, _) = parser.parse(content)
            if !calls.isEmpty {
                return calls.map { raw in
                    let args: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(raw.arguments.utf8))) as? [String: Any] ?? [:]
                    return AIToolCall(id: raw.id, name: raw.name, arguments: args)
                }
            }
        }
        return nil
    }
}

// MARK: - Default registry with all known parsers

extension ParserRegistry {
    /// Creates a registry pre-populated with all known parsers.
    public static func `default`() -> ParserRegistry {
        let r = ParserRegistry()
        r.register(JSONToolCallFormatParser())
        r.register(XMLToolCallFormatParser())
        r.register(LegacyToolCodeFormatParser())
        r.register(BareFunctionFormatParser())
        r.register(ToolCallBlockFormatParser())
        r.register(MinimaxFormatParser())
        r.register(GemmaFormatParser())
        return r
    }
}
