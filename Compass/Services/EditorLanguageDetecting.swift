protocol EditorLanguageDetecting {
    func detectLanguageForUntitledContent(currentLanguage: String, content: String) -> String?
    func languageForFileExtension(_ fileExtension: String) -> String
}
