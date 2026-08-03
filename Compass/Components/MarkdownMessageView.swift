import SwiftUI

struct MarkdownMessageView: View {
    let content: String
    var fontSize: Double
    var fontFamily: String

    var body: some View {
        MarkdownView(markdown: content, fontSize: fontSize, fontFamily: fontFamily) { code, language in
            CodePreviewView(
                code: code,
                language: language,
                title: language?.capitalized ?? "Code",
                fontSize: fontSize,
                fontFamily: fontFamily
            )
        }
    }
}
