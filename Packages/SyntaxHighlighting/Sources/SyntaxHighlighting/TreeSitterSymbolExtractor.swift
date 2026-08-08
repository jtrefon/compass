import Foundation
import SwiftTreeSitter
import CodeEditLanguages

/// Quality-first symbol extraction via tree-sitter AST.
/// Returns precise `lineStart…lineEnd` ranges (AST node extent) rather than
/// definition-line-only regex matches. Used by `SymbolExtractor` as the primary
/// path; regex fallback remains for unknown grammars (marked low-confidence).
public enum TreeSitterSymbolExtractor {

    public struct Symbol: Sendable {
        public let name: String
        public let kind: String
        public let lineStart: Int
        public let lineEnd: Int
        public let scope: String
        public let parentName: String
    }

    /// Attempt tree-sitter extraction. Returns nil when grammar unavailable or
    /// parse fails — caller must fallback to regex.
    public static func extract(content: String, languageId: String) -> [Symbol]? {
        guard let codeLang = resolveLanguage(languageId) else { return nil }
        guard let language = codeLang.language else { return nil }
        guard let queryURL = codeLang.queryURL else { return nil }

        let queriesDir = queryURL.deletingLastPathComponent()
        let config: LanguageConfiguration
        do {
            if let parent = codeLang.parentQueryURL, parent.deletingLastPathComponent() != queriesDir {
                let merged = try loadMergedQueries(for: language, from: [queriesDir, parent.deletingLastPathComponent()])
                config = LanguageConfiguration(language, name: codeLang.tsName, queries: merged)
            } else {
                config = try LanguageConfiguration(language, name: codeLang.tsName, queriesURL: queriesDir)
            }
        } catch {
            return nil
        }

        let parser = Parser()
        do { try parser.setLanguage(config.language) } catch { return nil }
        guard let tree = parser.parse(content) else { return nil }
        guard let root = tree.rootNode else { return nil }

        // Language-specific node types that denote a symbol boundary.
        let symbolTypes = symbolNodeTypes(for: codeLang)

        var results: [Symbol] = []
        walk(node: root, content: content, symbolTypes: symbolTypes, parentStack: [], results: &results)
        return results.isEmpty ? nil : results
    }

    // MARK: - Language resolution

    private static func resolveLanguage(_ identifier: String) -> CodeEditLanguages.CodeLanguage? {
        let normalized = identifier.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let lang = CodeEditLanguages.CodeLanguage.allLanguages.first(where: { $0.tsName.lowercased() == normalized }) {
            return lang
        }
        if let lang = CodeEditLanguages.CodeLanguage.allLanguages.first(where: { $0.extensions.contains(normalized) }) {
            return lang
        }
        switch normalized {
        case "js", "jsx": return .javascript
        case "ts": return .typescript
        case "tsx": return .tsx
        case "py": return .python
        case "sh","bash","zsh": return .bash
        case "swift": return .swift
        case "php": return .php
        case "yaml","yml": return .yaml
        case "json": return .json
        case "html","htm": return .html
        case "css": return .css
        case "md","markdown": return .markdown
        default: return nil
        }
    }

    private static func symbolNodeTypes(for lang: CodeEditLanguages.CodeLanguage) -> Set<String> {
        switch lang {
        case .swift:
            return ["class_declaration","struct_declaration","enum_declaration","protocol_declaration",
                    "extension_declaration","actor_declaration","function_declaration",
                    "variable_declaration","typealias_declaration","initializer_declaration","deinitializer_declaration"]
        case .javascript, .typescript, .tsx:
            return ["class_declaration","function_declaration","method_definition","lexical_declaration",
                    "variable_declaration","interface_declaration","type_alias_declaration","enum_declaration"]
        case .python:
            return ["class_definition","function_definition","decorated_definition"]
        case .php:
            return ["class_declaration","interface_declaration","trait_declaration","enum_declaration",
                    "function_definition","method_declaration","property_declaration"]
        case .bash:
            return ["function_definition","variable_assignment"]
        case .yaml:
            return ["block_mapping_pair","block_sequence_item"]
        default:
            return ["class_declaration","function_declaration","method_definition",
                    "class_definition","function_definition"]
        }
    }

    // MARK: - Walk

    private static func walk(node: Node, content: String, symbolTypes: Set<String>, parentStack: [String], results: inout [Symbol]) {
        let typeName = node.nodeType ?? ""

        if symbolTypes.contains(typeName) {
            if var extracted = extractSymbol(from: node, content: content, parentStack: parentStack) {
                results.append(extracted)
                var newParents = parentStack
                // Push class/interface names for child method parenting
                if typeName.contains("class") || typeName.contains("interface") || typeName.contains("struct") || typeName.contains("enum") {
                    newParents.append(extracted.name)
                }
                // Python methods: function_definition under a class gets "method"
                if typeName == "function_definition" && !parentStack.isEmpty {
                    extracted = Symbol(name: extracted.name, kind: "method", lineStart: extracted.lineStart,
                                       lineEnd: extracted.lineEnd, scope: extracted.scope, parentName: parentStack.last ?? "")
                    results[results.count - 1] = extracted
                }
                for i in 0..<node.childCount {
                    guard let child = node.child(at: i) else { continue }
                    walk(node: child, content: content, symbolTypes: symbolTypes, parentStack: newParents, results: &results)
                }
                return
            }
        }

        for i in 0..<node.childCount {
            guard let child = node.child(at: i) else { continue }
            walk(node: child, content: content, symbolTypes: symbolTypes, parentStack: parentStack, results: &results)
        }
    }

    private static func extractSymbol(from node: Node, content: String, parentStack: [String]) -> Symbol? {
        let typeName = node.nodeType ?? "unknown"
        let kind = mapKind(typeName)
        let name = extractName(from: node, content: content) ?? "unknown"

        // Skip unnamed wrappers
        guard name != "unknown" else { return nil }

        // JS/TS: `export function foo` — the declaration sits inside an export_statement
        let parentType = node.parent?.nodeType ?? ""
        let scope = parentType == "export_statement" ? "export" : ""

        let startRow = Int(node.pointRange.lowerBound.row) + 1
        let endRow = Int(node.pointRange.upperBound.row) + 1
        let clampedEnd = max(startRow, endRow)

        return Symbol(name: name, kind: kind, lineStart: startRow, lineEnd: clampedEnd, scope: scope, parentName: parentStack.last ?? "")
    }

    private static func mapKind(_ nodeType: String) -> String {
        if nodeType.contains("class") { return "class" }
        if nodeType.contains("struct") { return "struct" }
        if nodeType.contains("enum") { return "enum" }
        if nodeType.contains("protocol") || nodeType.contains("interface") { return "protocol" }
        if nodeType.contains("extension") { return "extension" }
        if nodeType.contains("actor") { return "actor" }
        if nodeType.contains("method") { return "method" }
        if nodeType.contains("function") || nodeType.contains("initializer") { return "function" }
        if nodeType.contains("variable") || nodeType.contains("lexical") || nodeType.contains("property") { return "variable" }
        if nodeType.contains("typealias") || nodeType.contains("type_alias") { return "typealias" }
        return "unknown"
    }

    private static func extractName(from node: Node, content: String) -> String? {
        // Preferred: named child "name" field
        if let nameNode = node.child(byFieldName: "name"), let t = nameNode.nodeType {
            if let text = textFor(node: nameNode, content: content), !text.isEmpty { return text }
            _ = t
        }
        // Fallback: scan children for identifier-like type
        for i in 0..<node.childCount {
            guard let child = node.child(at: i) else { continue }
            let ct = child.nodeType ?? ""
            if ct == "type_identifier" || ct == "identifier" || ct == "property_identifier" || ct.hasSuffix("_identifier") {
                if let text = textFor(node: child, content: content), !text.isEmpty { return text }
            }
        }
        // Deep fallback: first named child text
        for i in 0..<node.childCount {
            guard let child = node.child(at: i), child.isNamed else { continue }
            if let text = textFor(node: child, content: content), !text.isEmpty, text.count < 64 {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed.range(of: #"^[A-Za-z_][\w$]*$"#, options: .regularExpression) != nil {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func textFor(node: Node, content: String) -> String? {
        let range = node.range
        guard let swiftRange = Range(range, in: content) else { return nil }
        return String(content[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Query merging (mirrors TreeSitterHighlightService)

    private static func loadMergedQueries(for language: Language, from directories: [URL]) throws -> [Query.Definition: Query] {
        var mergedStrings: [Query.Definition: String] = [:]
        for dir in directories {
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isReadableKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "scm" else { continue }
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let definition: Query.Definition
                switch fileURL.lastPathComponent {
                case Query.Definition.injections.filename: definition = .injections
                case Query.Definition.highlights.filename: definition = .highlights
                case Query.Definition.locals.filename: definition = .locals
                default:
                    let filename = fileURL.lastPathComponent.replacingOccurrences(of: ".scm", with: "")
                    definition = .custom(filename)
                }
                mergedStrings[definition, default: ""].append(content + "\n")
            }
        }
        var queries: [Query.Definition: Query] = [:]
        for (definition, content) in mergedStrings {
            if let q = try? Query(language: language, data: Data(content.utf8)) {
                queries[definition] = q
            }
        }
        return queries
    }
}

