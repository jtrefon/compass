import Foundation

public enum EditorAIContextBuilder {
    public static func build(
        filePath: String?,
        language: String?,
        buffer: String,
        selection: NSRange?
    ) -> String {
        var parts: [String] = []

        if let filePath, !filePath.isEmpty {
            parts.append("File: \(filePath)")
        }
        if let language, !language.isEmpty {
            parts.append("Language: \(language)")
        }

        let ns = buffer as NSString
        let selectedText: String?
        if let selection,
           selection.location != NSNotFound,
           selection.length > 0,
           selection.location + selection.length <= ns.length {
            selectedText = ns.substring(with: selection)
        } else {
            selectedText = nil
        }

        if let selectedText, !selectedText.isEmpty {
            parts.append("Selected Code:\n\n\(selectedText)")
        } else if !buffer.isEmpty {
            parts.append("Buffer:\n\n\(buffer)")
        } else {
            parts.append("Buffer: <empty>")
        }

        return parts.joined(separator: "\n")
    }
}
