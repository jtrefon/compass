import Foundation

enum LanguageIndentUnitStyle: String, Codable {
    case tabs
    case spaces
}

struct LanguageFormattingConfiguration: Codable {
    let indentUnitStyle: LanguageIndentUnitStyle
    let indentWidth: Int
    let trimTrailingWhitespace: Bool
    let ensureTrailingNewline: Bool
    let maxConsecutiveBlankLines: Int

    static let `default` = LanguageFormattingConfiguration(
        indentUnitStyle: .spaces,
        indentWidth: 4,
        trimTrailingWhitespace: true,
        ensureTrailingNewline: true,
        maxConsecutiveBlankLines: 1
    )
}
