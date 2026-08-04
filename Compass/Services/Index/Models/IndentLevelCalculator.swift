import Foundation

struct IndentTransition {
    let indentLevelForLine: Int
    let nextIndentLevel: Int
}

struct IndentLevelCalculator {
    func computeIndentTransition(currentIndentLevel: Int, braceResult: BraceAnalysisResult) -> IndentTransition {
        let indentLevelForLine = braceResult.startsWithClosing
            ? max(0, currentIndentLevel - 1)
            : currentIndentLevel

        var nextIndentLevel = indentLevelForLine

        if braceResult.openingCount > braceResult.closingCount {
            nextIndentLevel += (braceResult.openingCount - braceResult.closingCount)
        } else if braceResult.closingCount > braceResult.openingCount {
            if !braceResult.startsWithClosing {
                nextIndentLevel = max(0, nextIndentLevel - (braceResult.closingCount - braceResult.openingCount))
            }
        }

        return IndentTransition(indentLevelForLine: indentLevelForLine, nextIndentLevel: nextIndentLevel)
    }
}
