import Foundation

public struct PythonParser {
    public static func parse(content: String, resourceId: String) -> [Symbol] {
        RegexLineSymbolParser.parse(
            content: content,
            resourceId: resourceId,
            patterns: [
                (.class, #"^\s*class\s+([A-Z][A-Za-z0-9_]*)\s*(?:\(|:)"#),
                (.function, #"^\s*def\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\("#),
                (.function, #"^\s*async\s+def\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\("#)
            ]
        )
    }
}
