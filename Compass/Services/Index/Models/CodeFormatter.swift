import Foundation

public struct CodeFormatter {
    public static func format(_ code: String, language: CodeLanguage) -> String {
        let config = LanguageFormattingConfiguration.default
        let indentString = IndentationStyle.current().indentUnit(tabWidth: max(1, config.indentWidth))
        let strategy: CodeFormattingStrategy = DefaultCodeFormattingStrategy()
        let formatted = strategy.format(code: code, language: language, indentUnit: indentString)
        return applyFormattingRules(formatted, configuration: config)
    }

    private static func applyFormattingRules(
        _ code: String,
        configuration: LanguageFormattingConfiguration
    ) -> String {
        var lines = code.components(separatedBy: .newlines)

        if configuration.trimTrailingWhitespace {
            lines = lines.map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        }

        let maxBlankLines = max(0, configuration.maxConsecutiveBlankLines)
        if maxBlankLines >= 0 {
            var collapsed: [String] = []
            var blankRunCount = 0
            for line in lines {
                if line.isEmpty {
                    blankRunCount += 1
                    if blankRunCount <= maxBlankLines {
                        collapsed.append(line)
                    }
                } else {
                    blankRunCount = 0
                    collapsed.append(line)
                }
            }
            lines = collapsed
        }

        var result = lines.joined(separator: "\n")
        if configuration.ensureTrailingNewline, !result.hasSuffix("\n") {
            result.append("\n")
        }
        if !configuration.ensureTrailingNewline, result.hasSuffix("\n") {
            result = String(result.dropLast())
        }
        return result
    }
}
