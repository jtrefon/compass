import Foundation

public struct TypeScriptParser {
    public static func parse(content: String, resourceId: String) -> [Symbol] {
        RegexLineSymbolParser.parse(
            content: content,
            resourceId: resourceId,
            patterns: [
                (.class, #"^\s*(?:export\s+)?class\s+([A-Z][A-Za-z0-9_]*)"#),
                (.protocol, #"^\s*(?:export\s+)?interface\s+([A-Z][A-Za-z0-9_]*)"#),
                (.function, #"^\s*(?:export\s+)?function\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\("#),
                (.function, #"^\s*(?:export\s+)?const\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*\([^)]*\)\s*=>"#),
                (.variable, #"^\s*(?:export\s+)?(?:const|let|var)\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*(?::\s*[^=;]+)?\s*="#)
            ]
        )
    }
}
