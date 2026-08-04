import AppKit
import Neon
import SwiftTreeSitter
import CodeEditLanguages

public enum TreeSitterHighlightError: Error, CustomStringConvertible {
    case unsupportedLanguage(String)
    case parseFailed(String)
    case noHighlightsQuery(String)

    public var description: String {
        switch self {
        case .unsupportedLanguage(let id):
            return "Unsupported language for tree-sitter highlighting: '\(id)'"
        case .parseFailed(let id):
            return "Failed to parse code for language '\(id)'"
        case .noHighlightsQuery(let id):
            return "No highlights query available for language '\(id)'"
        }
    }
}

@MainActor
public final class TreeSitterHighlightService {
    public static let shared = TreeSitterHighlightService()

    private let highlighters = NSMapTable<NSTextView, TextViewHighlighter>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private var languageConfigCache: [String: LanguageConfiguration] = [:]

    private init() {}

    public func attachHighlighter(to textView: NSTextView, languageIdentifier: String) {
        print("[TreeSitterHighlightService] attachHighlighter language=\(languageIdentifier)")
        detachHighlighter(from: textView)

        guard let langConfig = languageConfiguration(for: languageIdentifier) else {
            print("[TreeSitterHighlightService] No langConfig for '\(languageIdentifier)'")
            return
        }

        let config = TextViewHighlighter.Configuration(
            languageConfiguration: langConfig,
            attributeProvider: Self.attributeProvider,
            languageProvider: { _ in nil },
            locationTransformer: { [weak textView] offset in
                guard let textView else { return nil }
                let nsString = textView.string as NSString
                let safeOffset = min(max(0, offset), nsString.length)
                var lineStart = 0
                nsString.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: safeOffset, length: 0))
                let row = nsString.substring(to: safeOffset).reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                return Point(row: UInt32(row), column: UInt32(safeOffset - lineStart))
            }
        )

        do {
            let highlighter = try TextViewHighlighter(textView: textView, configuration: config)
            highlighters.setObject(highlighter, forKey: textView)
            highlighter.observeEnclosingScrollView()
        } catch {
            print("[TreeSitterHighlightService] Failed to create highlighter: \(error)")
        }
    }

    public func detachHighlighter(from textView: NSTextView) {
        highlighters.removeObject(forKey: textView)
    }

    private func languageConfiguration(for identifier: String) -> LanguageConfiguration? {
        let normalized = normalize(identifier)
        let cacheKey = normalized

        if let cached = languageConfigCache[cacheKey] {
            return cached
        }

        guard let codeLanguage = resolveCodeLanguage(normalized),
              let swiftLanguage = codeLanguage.language,
              let queryURL = codeLanguage.queryURL
        else { return nil }

        let queriesDir = queryURL.deletingLastPathComponent()

        do {
            let config: LanguageConfiguration

            if let parentQueryURL = codeLanguage.parentQueryURL {
                let parentDir = parentQueryURL.deletingLastPathComponent()
                if parentDir != queriesDir {
                    let merged = try Self.loadMergedQueries(for: swiftLanguage, from: [queriesDir, parentDir])
                    config = LanguageConfiguration(swiftLanguage, name: codeLanguage.tsName, queries: merged)
                } else {
                    config = try LanguageConfiguration(swiftLanguage, name: codeLanguage.tsName, queriesURL: queriesDir)
                }
            } else {
                config = try LanguageConfiguration(swiftLanguage, name: codeLanguage.tsName, queriesURL: queriesDir)
            }

            languageConfigCache[cacheKey] = config
            return config
        } catch {
            print("[TreeSitterHighlightService] Failed to create LanguageConfiguration for '\(identifier)': \(error)")
            return nil
        }
    }

    private static func loadMergedQueries(for language: Language, from directories: [URL]) throws -> [Query.Definition: Query] {
        var mergedStrings: [Query.Definition: String] = [:]

        for dir in directories {
            let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isReadableKey],
                options: [.skipsHiddenFiles]
            )

            guard let enumerator else {
                print("[TreeSitterHighlightService] Cannot enumerate queries dir: \(dir.path)")
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "scm" else { continue }
                guard try fileURL.resourceValues(forKeys: [.isReadableKey]).isReadable == true else { continue }

                let content = try String(contentsOf: fileURL, encoding: .utf8)

                let definition: Query.Definition
                switch fileURL.lastPathComponent {
                case Query.Definition.injections.filename:
                    definition = .injections
                case Query.Definition.highlights.filename:
                    definition = .highlights
                case Query.Definition.locals.filename:
                    definition = .locals
                default:
                    let filename = fileURL.lastPathComponent.replacingOccurrences(of: ".scm", with: "")
                    definition = .custom(filename)
                }

                mergedStrings[definition, default: ""].append(content + "\n")
            }
        }

        let highlightsLen = mergedStrings[.highlights]?.count ?? 0
        print("[TreeSitterHighlightService] Loaded \(mergedStrings.count) query types, highlights=\(highlightsLen) chars, keys=\(mergedStrings.keys.map(\.name))")

        var queries: [Query.Definition: Query] = [:]
        for (definition, content) in mergedStrings {
            do {
                queries[definition] = try Query(language: language, data: Data(content.utf8))
            } catch {
                print("[TreeSitterHighlightService] Skipping query '\(definition.name)': \(error)")
            }
        }
        return queries
    }

    private func resolveCodeLanguage(_ identifier: String) -> CodeEditLanguages.CodeLanguage? {
        if let lang = CodeEditLanguages.CodeLanguage.allLanguages.first(where: {
            $0.tsName.lowercased() == identifier
        }) {
            return lang
        }

        if let lang = CodeEditLanguages.CodeLanguage.allLanguages.first(where: {
            $0.extensions.contains(identifier)
        }) {
            return lang
        }

        switch identifier {
        case "js":
            return .javascript
        case "jsx":
            return .javascript
        case "ts":
            return .typescript
        case "tsx", "typescriptreact", "typescript_react":
            return .tsx
        case "py":
            return .python
        case "sh", "bash", "zsh":
            return .bash
        case "c", "h":
            return .c
        case "cpp", "cc", "cxx", "hpp":
            return .cpp
        case "md", "markdown":
            return .markdown
        case "yaml", "yml":
            return .yaml
        case "json":
            return .json
        case "html", "htm":
            return .html
        case "css":
            return .css
        case "swift":
            return .swift
        case "php":
            return .php
        default:
            return nil
        }
    }

    private func normalize(_ raw: String) -> String {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.hasPrefix("language_") {
            normalized.removeFirst("language_".count)
        }
        if normalized.hasPrefix(".") {
            normalized.removeFirst()
        }

        return normalized
    }

    // MARK: - Debug

    private static let logUnknownTokens = false

    // MARK: - Offline / Preview Highlighting

    /// Highlights a plain string using tree-sitter, returning an `NSAttributedString`.
    /// Uses the same `attributeProvider` and color scheme as the live editor.
    public func highlightPreview(code: String, languageIdentifier: String) throws -> NSAttributedString {
        guard let langConfig = languageConfiguration(for: languageIdentifier) else {
            throw TreeSitterHighlightError.unsupportedLanguage(languageIdentifier)
        }

        let parser = Parser()
        try parser.setLanguage(langConfig.language)

        guard let tree = parser.parse(code) else {
            throw TreeSitterHighlightError.parseFailed(languageIdentifier)
        }

        guard let highlightsQuery = langConfig.queries[.highlights] else {
            throw TreeSitterHighlightError.noHighlightsQuery(languageIdentifier)
        }

        let result = NSMutableAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: Self.nsColor(0xDC, 0xDC, 0xDC)
        ])

        let namedRanges = highlightsQuery.execute(in: tree).highlights()

        for nr in namedRanges {
            let token = Token(name: nr.name, range: nr.range)
            let attrs = Self.attributeProvider(token)
            if let color = attrs[NSAttributedString.Key.foregroundColor] as? NSColor {
                result.addAttribute(NSAttributedString.Key.foregroundColor, value: color, range: nr.range)
            }
        }

        return result
    }

    // MARK: - Color Scheme (VS Code Dark+ inspired)

    private static let attributeProvider: TokenAttributeProvider = { token in
        var attrs: [NSAttributedString.Key: Any] = [:]

        switch token.name {
        // --- Keywords (blue) ---
        case let s where s == "keyword" || s.hasPrefix("keyword."):
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- Control flow (blue) ---
        case let s where s.hasPrefix("keyword.control") || s == "conditional" || s == "repeat" || s == "return" || s == "exception":
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- Import / module / include (yellow) ---
        case let s where s.hasPrefix("keyword.import") || s.hasPrefix("include") || s == "module" || s.hasPrefix("keyword.module") || s == "import":
            attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xAA)

        // --- Storage / declaration keywords (blue) ---
        case let s where s.hasPrefix("keyword.type") || s == "storage" || s.hasPrefix("storage.") || s.hasPrefix("keyword.declaration"):
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- Declaration keywords (struct/class/enum/protocol) ---
        case let s where s.hasPrefix("keyword.struct") || s.hasPrefix("keyword.class") || s.hasPrefix("keyword.enum") || s.hasPrefix("keyword.protocol") || s.hasPrefix("keyword.interface"):
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- Strings (orange) ---
        case let s where s == "string" || s.hasPrefix("string.") || s == "template_string" || s.hasPrefix("string.template"):
            attrs[.foregroundColor] = nsColor(0xCE, 0x91, 0x78)

        // --- String escape sequences (gold) ---
        case let s where s.hasPrefix("string.escape") || s.hasPrefix("escape"):
            attrs[.foregroundColor] = nsColor(0xD7, 0xBA, 0x7D)

        // --- Regex / special strings (orange-red) ---
        case let s where s.hasPrefix("string.regex") || s == "regex" || s.hasPrefix("regex."):
            attrs[.foregroundColor] = nsColor(0xD1, 0x69, 0x69)

        // --- Comments (green) ---
        case let s where s == "comment" || s.hasPrefix("comment."):
            attrs[.foregroundColor] = nsColor(0x6A, 0x99, 0x55)

        // --- Numbers (mint green) ---
        case let s where s == "number" || s.hasPrefix("number.") || s == "float" || s.hasPrefix("float."):
            attrs[.foregroundColor] = nsColor(0xB5, 0xCE, 0xA8)

        // --- Constants (cyan blue) ---
        case let s where s == "constant" || s.hasPrefix("constant."):
            attrs[.foregroundColor] = nsColor(0x4F, 0xC1, 0xFF)

        // --- Boolean & nil (blue) ---
        case let s where s == "boolean" || s == "nil" || s == "null" || s == "undefined":
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- Built-in constants (true, false, self, this) ---
        case let s where s == "self" || s == "this" || s == "super":
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- Types (teal) ---
        case let s where s == "type" || s.hasPrefix("type.") || s.hasPrefix("type_builtin"):
            attrs[.foregroundColor] = nsColor(0x4E, 0xC9, 0xB0)

        // --- Built-in types (teal) ---
        case let s where s.hasPrefix("type.builtin") || s == "builtin_type" || s.hasPrefix("type.language"):
            attrs[.foregroundColor] = nsColor(0x4E, 0xC9, 0xB0)

        // --- Type parameters (teal, italic) ---
        case let s where s.hasPrefix("type.parameter") || s == "type_argument":
            attrs[.foregroundColor] = nsColor(0x4E, 0xC9, 0xB0)

        // --- Functions & methods (yellow) ---
        case let s where s == "function" || s.hasPrefix("function.") || s == "method" || s.hasPrefix("method."):
            attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xAA)

        // --- Function/method calls (yellow) ---
        case let s where s.hasPrefix("function.call") || s.hasPrefix("method.call") || s == "call_expression":
            attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xAA)

        // --- Function definitions (yellow) ---
        case let s where s.hasPrefix("function.declaration") || s.hasPrefix("method.declaration") || s == "function_definition" || s == "method_definition":
            attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xAA)

        // --- Function parameters (light blue) ---
        case let s where s.hasPrefix("parameter") || s.hasPrefix("variable.parameter") || s == "function_param" || s == "method_param":
            attrs[.foregroundColor] = nsColor(0x9C, 0xDC, 0xFE)

        // --- Variables (light blue) ---
        case let s where s == "variable" || s.hasPrefix("variable."):
            attrs[.foregroundColor] = nsColor(0x9C, 0xDC, 0xFE)

        // --- Built-in variables (self, this, arguments) (blue) ---
        case let s where s.hasPrefix("variable.builtin") || s == "variable.language" || s == "builtin_object":
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- Properties / member access (light blue) ---
        case let s where s == "property" || s.hasPrefix("property.") || s.hasPrefix("member") || s == "member_access":
            attrs[.foregroundColor] = nsColor(0x9C, 0xDC, 0xFE)

        // --- Labels (yellow) ---
        case let s where s == "label" || s.hasPrefix("label."):
            attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xAA)

        // --- Operators (gray) ---
        case let s where s == "operator" || s.hasPrefix("operator.") || s == "keyword.operator":
            attrs[.foregroundColor] = nsColor(0xD4, 0xD4, 0xD4)

        // --- Punctuation (gray) ---
        case let s where s == "punctuation" || s.hasPrefix("punctuation."):
            attrs[.foregroundColor] = nsColor(0xD4, 0xD4, 0xD4)

        // --- Delimiters (gray) ---
        case let s where s.hasPrefix("punctuation.delimiter") || s == "delimiter":
            attrs[.foregroundColor] = nsColor(0xD4, 0xD4, 0xD4)

        // --- Brackets (gray) ---
        case let s where s.hasPrefix("punctuation.bracket") || s == "bracket":
            attrs[.foregroundColor] = nsColor(0xD4, 0xD4, 0xD4)

        // --- HTML/XML tags (blue) ---
        case let s where s == "tag" || s.hasPrefix("tag."):
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- HTML tag names (blue) ---
        case let s where s.hasPrefix("tag.name") || s == "element":
            attrs[.foregroundColor] = nsColor(0x56, 0x9C, 0xD6)

        // --- HTML attributes (light blue) ---
        case let s where s.hasPrefix("attribute") || s.hasPrefix("tag.attribute"):
            attrs[.foregroundColor] = nsColor(0x9C, 0xDC, 0xFE)

        // --- CSS class names (gold) ---
        case let s where s == "class" || s.hasPrefix("class.") || s == "className" || s == "class_name":
            attrs[.foregroundColor] = nsColor(0xD7, 0xBA, 0x7D)

        // --- CSS IDs (light blue) ---
        case let s where s == "id" || s.hasPrefix("id.") || s == "ID" || s == "css_id":
            attrs[.foregroundColor] = nsColor(0x9C, 0xDC, 0xFE)

        // --- Decorators / annotations (purple) ---
        case let s where s == "decorator" || s.hasPrefix("decorator.") || s == "annotation" || s.hasPrefix("annotation."):
            attrs[.foregroundColor] = nsColor(0xC5, 0x86, 0xC0)

        // --- Macros / preprocessor (purple) ---
        case let s where s == "macro" || s.hasPrefix("macro.") || s == "preproc" || s.hasPrefix("preproc.") || s.hasPrefix("preprocessor"):
            attrs[.foregroundColor] = nsColor(0xC5, 0x86, 0xC0)

        // --- Attributes / modifiers (purple) ---
        case let s where s.hasPrefix("attribute") || s == "modifier" || s == "keyword.modifier":
            attrs[.foregroundColor] = nsColor(0xC5, 0x86, 0xC0)

        // --- Namespaces (teal) ---
        case let s where s == "namespace" || s.hasPrefix("namespace."):
            attrs[.foregroundColor] = nsColor(0x4E, 0xC9, 0xB0)

        // --- Constructor (yellow, like functions) ---
        case let s where s == "constructor" || s.hasPrefix("constructor."):
            attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xAA)

        // --- Embedded languages (orange, like strings) ---
        case let s where s.hasPrefix("embedded") || s.hasPrefix("interpolation"):
            attrs[.foregroundColor] = nsColor(0xCE, 0x91, 0x78)

        // --- Keywords in other languages (CSS @media, @import, etc) ---
        case let s where s.hasPrefix("keyword.at") || s == "at_keyword":
            attrs[.foregroundColor] = nsColor(0xC5, 0x86, 0xC0)

        default:
            if logUnknownTokens {
                print("[token] UNKNOWN: '\(token.name)' range=\(token.range) length=\(token.range.length)")
            }
            attrs[.foregroundColor] = nsColor(0xDC, 0xDC, 0xDC)
        }

        return attrs
    }

    private static func nsColor(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(calibratedRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)
    }
}
