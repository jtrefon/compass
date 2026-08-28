import Foundation

protocol CodeFormattingStrategy {
    func format(code: String, language: CodeLanguage, indentUnit: String) -> String
}
