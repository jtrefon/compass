import Foundation

struct DefaultCodeFormattingStrategy: CodeFormattingStrategy {
    private let braceAnalyzer = BraceAnalyzer()
    private let indentLevelCalculator = IndentLevelCalculator()

    func format(code: String, language _: CodeLanguage, indentUnit: String) -> String {
        let lines = code.components(separatedBy: .newlines)
        var formattedLines: [String] = []
        var indentLevel = 0

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty {
                formattedLines.append("")
                continue
            }

            let braceResult = braceAnalyzer.analyze(trimmedLine)
            let transition = indentLevelCalculator.computeIndentTransition(
                currentIndentLevel: indentLevel,
                braceResult: braceResult
            )

            let currentIndent = String(repeating: indentUnit, count: transition.indentLevelForLine)
            formattedLines.append(currentIndent + trimmedLine)

            indentLevel = transition.nextIndentLevel
        }

        return formattedLines.joined(separator: "\n")
    }
}
