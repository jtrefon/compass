import SwiftUI
import SyntaxHighlighting

struct CodePreviewView: View {
    let code: String
    let language: String?
    let title: String
    var fontSize: Double
    var fontFamily: String
    @State private var isCopied = false

    init(
        code: String,
        language: String? = nil,
        title: String = "Code Preview",
        fontSize: Double = 12,
        fontFamily: String = AppConstants.Editor.defaultFontFamily
    ) {
        self.code = code
        self.language = language
        self.title = title
        self.fontSize = fontSize
        self.fontFamily = fontFamily
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppConstants.Layout.spacingSm) {
            header

            highlightedText
                .padding(AppConstants.Layout.spacingSm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppConstants.Color.surfaceEditor)
                .cornerRadius(AppConstants.Layout.cornerXs)
        }
        .padding(.top, AppConstants.Layout.spacingXS)
    }

    private var header: some View {
        HStack {
            SwiftUI.Text(title)
                .font(.caption)
                .foregroundStyle(AppConstants.Color.textSecondary)

            if let language = language {
                SwiftUI.Text("\u{2022}")
                    .font(.caption)
                    .foregroundStyle(AppConstants.Color.textSecondary)
                SwiftUI.Text(language)
                    .font(.caption)
                    .foregroundStyle(AppConstants.Color.textSecondary)
                    .padding(.horizontal, AppConstants.Layout.spacingXS)
                    .padding(.vertical, AppConstants.Layout.spacingXXS)
                    .background(AppConstants.Color.surfaceCard)
                    .cornerRadius(AppConstants.Layout.cornerXs)
            }

            Spacer()

            Button(action: copyCode) {
                HStack {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    SwiftUI.Text(isCopied ? "Copied!" : "Copy")
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppConstants.Color.alertInfo)
        }
    }

    @ViewBuilder
    private var highlightedText: some View {
        if let attributed = highlightedAttributedString {
            SwiftUI.Text(attributed)
        } else {
            SwiftUI.Text(code)
                .font(resolveFont(size: fontSize, family: fontFamily))
        }
    }

    private var highlightedAttributedString: AttributedString? {
        guard let language = language else { return nil }
        guard let nsAttributed = try? TreeSitterHighlightService.shared.highlightPreview(
            code: code,
            languageIdentifier: language
        ) else {
            return nil
        }
        return AttributedString(nsAttributed)
    }

    private func resolveFont(size: Double, family: String) -> Font {
        if let nsFont = NSFont(name: family, size: CGFloat(size)) {
            return Font(nsFont)
        }
        return .system(size: CGFloat(size), weight: .regular, design: .monospaced)
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)

        isCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                isCopied = false
            }
        }
    }
}

struct CodePreviewView_Previews: PreviewProvider {
    static var previews: some View {
        CodePreviewView(
            code: "func helloWorld() {\n    print(\"Hello, World!\")\n}",
            fontSize: 12,
            fontFamily: AppConstants.Editor.defaultFontFamily
        )
        .padding()
    }
}
