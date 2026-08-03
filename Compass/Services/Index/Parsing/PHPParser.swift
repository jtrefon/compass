import Foundation

public struct PHPParser {
    public static func parse(content: String, resourceId: String) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = content.components(separatedBy: .newlines)

        let patterns: [(kind: SymbolKind, pattern: String)] = [
            (.class, #"^\s*class\s+([A-Za-z_]\w*)"#),
            (.class, #"^\s*interface\s+([A-Za-z_]\w*)"#),
            (.class, #"^\s*trait\s+([A-Za-z_]\w*)"#),
            (.function, #"^\s*(?:public\s+|private\s+|protected\s+|static\s+)*function\s+([A-Za-z_]\w*)\s*\("#),
        ]

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1

            for (kind, pattern) in patterns {
                if let match = matchRegex(pattern, in: line) {
                    let id = "\(resourceId):\(lineNum):\(match)"

                    let symbol = Symbol(
                        id: id,
                        resourceId: resourceId,
                        name: match,
                        kind: kind,
                        lineStart: lineNum,
                        lineEnd: lineNum,
                        description: nil
                    )
                    symbols.append(symbol)
                    break
                }
            }
        }

        return symbols
    }

    private static func matchRegex(_ pattern: String, in text: String) -> String? {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let nsString = text as NSString
            let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

            if let result = results.first, result.numberOfRanges > 1 {
                return nsString.substring(with: result.range(at: 1))
            }
        } catch {
        }
        return nil
    }
}
