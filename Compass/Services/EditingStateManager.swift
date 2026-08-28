import Foundation

@MainActor
final class EditingStateManager {
    private let languageDetector: EditorLanguageDetecting

    struct UpdateEditorContentRequest {
        let newContent: String
        let selectedFile: String?
        let currentLanguage: String
        let applyContent: (String) -> Void
        let applyLanguage: (String) -> Void
        let updateServiceContent: (String) -> Void
    }

    init(languageDetector: EditorLanguageDetecting) {
        self.languageDetector = languageDetector
    }

    func updateEditorContent(_ request: UpdateEditorContentRequest) {
        request.applyContent(request.newContent)
        request.updateServiceContent(request.newContent)

        guard request.selectedFile == nil else { return }
        guard let detected = languageDetector.detectLanguageForUntitledContent(
            currentLanguage: request.currentLanguage,
            content: request.newContent
        ) else { return }

        request.applyLanguage(detected)
    }

    func setEditorLanguage(
        language: String,
        applyLanguage: (String) -> Void,
        updateServiceLanguage: (String) -> Void
    ) {
        applyLanguage(language)
        updateServiceLanguage(language)
    }
}
