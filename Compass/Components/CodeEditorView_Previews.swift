import SwiftUI

struct CodeEditorView_Previews: PreviewProvider {
    @MainActor
    private static var previewLineCompletionEngine: LineCompletionEngine {
        LineCompletionEngine(
            inferenceService: CompletionInferenceService(provider: AIServiceInlineCompletionProvider(aiServiceProvider: { nil }))
        )
    }

    @MainActor
    static var previews: some View {
        CodeEditorView(
            paneID: .primary,
            text: .constant("func helloWorld() {\n    print(\"Hello, World!\")\n}"),
            filePath: nil,
            language: "swift",
            selectedRange: .constant(nil),
            selectionContext: CodeSelectionContext(),
            lineCompletionEngine: previewLineCompletionEngine,
            inlineCompletionDebugOverlayEnabled: true,
            showLineNumbers: true,
            wordWrap: false,
            fontSize: AppConstantsEditor.defaultFontSize,
            fontFamily: AppConstantsEditor.defaultFontFamily
        )
        .frame(height: 300)
    }
}
