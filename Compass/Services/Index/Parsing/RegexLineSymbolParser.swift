import Foundation

enum RegexLineSymbolParser {
    typealias Pattern = (kind: SymbolKind, pattern: String)

    static func parse(
        content: String,
        resourceId: String,
        patterns: [Pattern],
        symbolNameForMatch: (_ kind: SymbolKind, _ match: String) -> String = { _, match in match }
    ) -> [Symbol] {
        var symbols: [Symbol] = []
        let lines = content.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            for (kind, pattern) in patterns {
                if let match = matchRegex(pattern, in: line) {
                    let name = symbolNameForMatch(kind, match)
                    let id = "\(resourceId):\(lineNum):\(name)"
                    symbols.append(
                        Symbol(
                            id: id,
                            resourceId: resourceId,
                            name: name,
                            kind: kind,
                            lineStart: lineNum,
                            lineEnd: lineNum,
                            description: nil
                        )
                    )
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
