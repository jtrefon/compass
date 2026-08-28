import Foundation
#if canImport(SyntaxHighlighting)
import SyntaxHighlighting
#endif

public struct ExtractedSymbol: Sendable {
    public let name: String
    public let kind: String
    public let scope: String
    public let signature: String
    public let parentName: String
    public let lineStart: Int
    public let lineEnd: Int
    public let filePath: String
}

public enum SymbolExtractor {
    public static func extract(from url: URL, content: String) -> [ExtractedSymbol] {
        // Tree-sitter primary path — precise AST ranges (lineEnd = node end, not definition line)
        if let tsSymbols = tryTreeSitterExtract(from: url, content: content), !tsSymbols.isEmpty {
            return tsSymbols
        }
        // Regulated fallback — also computes surgical lineEnd via brace/indent scope
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "swift": return extractSwift(content: content, filePath: url.path)
        case "js", "jsx", "mjs": return extractJSTS(content: content, filePath: url.path)
        case "ts", "tsx": return extractJSTS(content: content, filePath: url.path)
        case "py": return extractPython(content: content, filePath: url.path)
        case "php": return extractPHP(content: content, filePath: url.path)
        case "yaml", "yml": return extractYAML(content: content, filePath: url.path)
        case "sh", "bash", "zsh": return extractSh(content: content, filePath: url.path)
        default: return extractGeneric(content: content, filePath: url.path)
        }
    }

    private static func tryTreeSitterExtract(from url: URL, content: String) -> [ExtractedSymbol]? {
        #if canImport(SyntaxHighlighting)
        if let ts = TreeSitterSymbolExtractor.extract(content: content, languageId: url.pathExtension.lowercased()) {
            return ts.map { s in
                ExtractedSymbol(name: s.name, kind: s.kind, scope: s.scope, signature: "",
                                parentName: s.parentName, lineStart: s.lineStart, lineEnd: s.lineEnd, filePath: url.path)
            }
        }
        #endif
        return nil
    }
}

// MARK: - Pattern cache

private let regexCache: [String: NSRegularExpression] = {
    let patterns = [
        "swift_type": "\\b(actor|class|struct|enum|protocol|extension)\\s+([A-Za-z_]\\w*)",
        "swift_method": "\\b(func|static\\s+func|class\\s+func)\\s+([A-Za-z_]\\w*)\\s*\\(",
        "swift_property": "\\b(var|let)\\s+([A-Za-z_]\\w*)\\s*[=:]",
        "swift_typealias": "\\btypealias\\s+([A-Za-z_]\\w*)",
        "swift_scope": "\\b(public|private|internal|fileprivate|open|static|class)\\b",
        "swift_sig": "\\(.*?\\)\\s*(async)?\\s*(throws)?\\s*->\\s*[^\\{;]+",
        "jsts_class": "\\b(class|interface)\\s+([A-Za-z_]\\w*)",
        "jsts_func": "\\b(function|const|let|var)\\s+([A-Za-z_]\\w*)\\s*[=:(]",
        "jsts_export": "export\\s+(default\\s+)?(function|class)\\s+([A-Za-z_]\\w*)",
        "py_class": "\\bclass\\s+([A-Za-z_]\\w*)\\s*[(:]",
        "py_def": "\\bdef\\s+([A-Za-z_]\\w*)\\s*\\(",
        "php_class": "\\b(class|interface|trait)\\s+([A-Za-z_]\\w*)",
        "php_function": "\\bfunction\\s+([A-Za-z_]\\w*)\\s*\\(",
        "php_scope": "\\b(public|private|protected|static)\\b",
        "php_property": "\\b(public|private|protected)\\s+\\$([A-Za-z_]\\w*)"
    ]
    var cache: [String: NSRegularExpression] = [:]
    for (key, pattern) in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern) {
            cache[key] = regex
        }
    }
    return cache
}()

private func match(_ text: String, key: String) -> [String]? {
    guard let regex = regexCache[key] else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    var groups: [String] = []
    for index in 0..<match.numberOfRanges {
        guard let range = Range(match.range(at: index), in: text) else { continue }
        groups.append(String(text[range]))
    }
    return groups
}

// MARK: - Surgical helpers (quality-first, no quick patch)

private func surgicalBraceEnd(from startLine: Int, lines: [String]) -> Int {
    // Uses BraceAnalyzer semantics to find the matching closing scope.
    // If no brace scope starts within 5 lines, return startLine (single-line symbol).
    guard startLine >= 1, startLine <= lines.count else { return startLine }
    var depth = 0
    var started = false
    let analyzer = BraceAnalyzer()
    for idx in (startLine - 1)..<lines.count {
        let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
        let r = analyzer.analyze(trimmed)
        if !started {
            if r.openingCount > 0 {
                started = true
                depth += r.openingCount - r.closingCount
                if depth <= 0 { return idx + 1 }
            } else if idx - (startLine - 1) > 5 {
                // No scope opened in reasonable window — single-line symbol
                return startLine
            }
        } else {
            depth += r.openingCount - r.closingCount
            if depth <= 0 { return idx + 1 }
        }
    }
    return started ? lines.count : startLine
}

private func surgicalIndentEnd(from startLine: Int, startIndent: Int, lines: [String]) -> Int {
    guard startLine >= 1, startLine <= lines.count else { return startLine }
    var end = startLine
    for idx in startLine..<lines.count {
        let line = lines[idx]
        if line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        if indent <= startIndent { break }
        end = idx + 1
    }
    return end
}

// MARK: - Swift

private func extractSwift(content: String, filePath: String) -> [ExtractedSymbol] {
    let lines = content.components(separatedBy: .newlines)
    var symbols: [ExtractedSymbol] = []
    var lastTypeName = ""

    for (lineIndex, line) in lines.enumerated() {
        let lineNum = lineIndex + 1
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let groups = match(trimmed, key: "swift_type") {
            let kind = groups[1]
            let name = groups[2]
            let scope = extractSwiftScope(from: trimmed)
            let parent = kind == "extension" ? name : ""
            let end = surgicalBraceEnd(from: lineNum, lines: lines)
            let sym = ExtractedSymbol(name: name, kind: kind, scope: scope, signature: "",
                                      parentName: parent, lineStart: lineNum, lineEnd: end,
                                      filePath: filePath)
            symbols.append(sym)
            if kind != "extension" { lastTypeName = name }
            continue
        }

        if let groups = match(trimmed, key: "swift_method") {
            let name = groups[2]
            let scope = extractSwiftScope(from: trimmed)
            let sig = extractSwiftSignature(line: trimmed)
            let end = surgicalBraceEnd(from: lineNum, lines: lines)
            let sym = ExtractedSymbol(name: name, kind: "method", scope: scope, signature: sig,
                                      parentName: lastTypeName, lineStart: lineNum, lineEnd: end,
                                      filePath: filePath)
            symbols.append(sym)
            continue
        }

        if let groups = match(trimmed, key: "swift_property") {
            let name = groups[2]
            let scope = extractSwiftScope(from: trimmed)
            let sym = ExtractedSymbol(name: name, kind: "property", scope: scope, signature: "",
                                      parentName: lastTypeName, lineStart: lineNum, lineEnd: lineNum,
                                      filePath: filePath)
            symbols.append(sym)
            continue
        }

        if let groups = match(trimmed, key: "swift_typealias") {
            let sym = ExtractedSymbol(name: groups[1], kind: "typealias", scope: "", signature: "",
                                      parentName: lastTypeName, lineStart: lineNum, lineEnd: lineNum,
                                      filePath: filePath)
            symbols.append(sym)
            continue
        }
    }

    return symbols
}

private func extractSwiftScope(from line: String) -> String {
    guard let groups = match(line, key: "swift_scope"), groups.count > 1 else { return "" }
    return groups[1]
}

private func extractSwiftSignature(line: String) -> String {
    guard let groups = match(line, key: "swift_sig"), groups.count > 0 else { return "" }
    return groups[0]
}

// MARK: - JS/TS

private func extractJSTS(content: String, filePath: String) -> [ExtractedSymbol] {
    let lines = content.components(separatedBy: .newlines)
    var symbols: [ExtractedSymbol] = []
    var lastClassName = ""

    for (lineIndex, line) in lines.enumerated() {
        let lineNum = lineIndex + 1
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if let groups = match(trimmed, key: "jsts_class") {
            let end = surgicalBraceEnd(from: lineNum, lines: lines)
            let sym = ExtractedSymbol(name: groups[2], kind: groups[1], scope: extractJSScope(from: trimmed),
                                      signature: "", parentName: "", lineStart: lineNum, lineEnd: end,
                                      filePath: filePath)
            symbols.append(sym)
            lastClassName = groups[2]
            continue
        }

        if let groups = match(trimmed, key: "jsts_func") {
            let kind = groups[1] == "function" ? "function" : "variable"
            let end = surgicalBraceEnd(from: lineNum, lines: lines)
            let sym = ExtractedSymbol(name: groups[2], kind: kind, scope: extractJSScope(from: trimmed),
                                      signature: "", parentName: lastClassName, lineStart: lineNum,
                                      lineEnd: end, filePath: filePath)
            symbols.append(sym)
            continue
        }

        if let groups = match(trimmed, key: "jsts_export") {
            let end = surgicalBraceEnd(from: lineNum, lines: lines)
            let sym = ExtractedSymbol(name: groups[3], kind: groups[2], scope: "export", signature: "",
                                      parentName: lastClassName, lineStart: lineNum, lineEnd: end,
                                      filePath: filePath)
            symbols.append(sym)
            continue
        }
    }

    return symbols
}

private func extractJSScope(from line: String) -> String {
    line.contains("export ") ? "export" : ""
}

// MARK: - Python

private func extractPython(content: String, filePath: String) -> [ExtractedSymbol] {
    let lines = content.components(separatedBy: .newlines)
    var symbols: [ExtractedSymbol] = []
    var lastClassName = ""
    var lastClassIndent = -1

    for (lineIndex, line) in lines.enumerated() {
        let lineNum = lineIndex + 1
        let indent = line.prefix(while: { $0 == " " }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

        if let groups = match(trimmed, key: "py_class") {
            let end = surgicalIndentEnd(from: lineNum, startIndent: indent, lines: lines)
            let sym = ExtractedSymbol(name: groups[1], kind: "class", scope: "", signature: "",
                                      parentName: "", lineStart: lineNum, lineEnd: end,
                                      filePath: filePath)
            symbols.append(sym)
            lastClassName = groups[1]
            lastClassIndent = indent
            continue
        }

        if let groups = match(trimmed, key: "py_def") {
            let isMethod = indent > lastClassIndent && !lastClassName.isEmpty
            let end = surgicalIndentEnd(from: lineNum, startIndent: indent, lines: lines)
            let sym = ExtractedSymbol(name: groups[1], kind: isMethod ? "method" : "function",
                                      scope: "", signature: "",
                                      parentName: isMethod ? lastClassName : "",
                                      lineStart: lineNum, lineEnd: end, filePath: filePath)
            symbols.append(sym)
            continue
        }
    }

    return symbols
}

private func extractPHP(content: String, filePath: String) -> [ExtractedSymbol] {
    let lines = content.components(separatedBy: .newlines)
    var symbols: [ExtractedSymbol] = []
    var lastClassName = ""

    for (lineIndex, line) in lines.enumerated() {
        let lineNum = lineIndex + 1
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#"), !trimmed.hasPrefix("/*") else { continue }

        if let groups = match(trimmed, key: "php_class") {
            let end = surgicalBraceEnd(from: lineNum, lines: lines)
            let sym = ExtractedSymbol(name: groups[2], kind: groups[1], scope: extractPHPScope(from: trimmed),
                                      signature: "", parentName: "", lineStart: lineNum, lineEnd: end,
                                      filePath: filePath)
            symbols.append(sym)
            lastClassName = groups[2]
            continue
        }

        if let groups = match(trimmed, key: "php_function") {
            let scope = extractPHPScope(from: trimmed)
            let end = surgicalBraceEnd(from: lineNum, lines: lines)
            let sym = ExtractedSymbol(name: groups[1], kind: "function", scope: scope, signature: "",
                                      parentName: lastClassName, lineStart: lineNum, lineEnd: end,
                                      filePath: filePath)
            symbols.append(sym)
            continue
        }

        if let groups = match(trimmed, key: "php_property") {
            let sym = ExtractedSymbol(name: groups[2], kind: "property", scope: groups[1], signature: "",
                                      parentName: lastClassName, lineStart: lineNum, lineEnd: lineNum,
                                      filePath: filePath)
            symbols.append(sym)
            continue
        }
    }

    return symbols
}

private func extractPHPScope(from line: String) -> String {
    guard let groups = match(line, key: "php_scope"), groups.count > 1 else { return "" }
    return groups[1]
}

// MARK: - YAML / Shell / Generic

private func extractYAML(content: String, filePath: String) -> [ExtractedSymbol] {
    let lines = content.components(separatedBy: .newlines)
    var symbols: [ExtractedSymbol] = []
    for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        // Key: value or key:  (mapping)
        if let colon = trimmed.firstIndex(of: ":") {
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.range(of: #"^[A-Za-z_][\w\-\.]*$"#, options: .regularExpression) != nil else { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            let end = surgicalIndentEnd(from: idx + 1, startIndent: indent, lines: lines)
            symbols.append(ExtractedSymbol(name: key, kind: "variable", scope: "", signature: "", parentName: "", lineStart: idx + 1, lineEnd: end, filePath: filePath))
        }
    }
    return symbols
}

private func extractSh(content: String, filePath: String) -> [ExtractedSymbol] {
    let lines = content.components(separatedBy: .newlines)
    var symbols: [ExtractedSymbol] = []
    let funcRegex = try? NSRegularExpression(pattern: #"^\s*(?:function\s+)?([A-Za-z_][\w]*)\s*\(\)"#)
    for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        let ns = trimmed as NSString
        if let m = funcRegex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
            let name = ns.substring(with: m.range(at: 1))
            let end = surgicalBraceEnd(from: idx + 1, lines: lines)
            symbols.append(ExtractedSymbol(name: name, kind: "function", scope: "", signature: "", parentName: "", lineStart: idx + 1, lineEnd: end, filePath: filePath))
        }
    }
    return symbols
}

private func extractGeneric(content: String, filePath: String) -> [ExtractedSymbol] {
    // Fallback for unknown extensions: surface top-level headings as symbols so search still returns surgical ranges
    let lines = content.components(separatedBy: .newlines)
    var symbols: [ExtractedSymbol] = []
    for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") {
            let name = trimmed.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            guard !name.isEmpty else { continue }
            symbols.append(ExtractedSymbol(name: String(name.prefix(64)), kind: "variable", scope: "", signature: "", parentName: "", lineStart: idx + 1, lineEnd: idx + 1, filePath: filePath))
        }
    }
    return symbols
}

// MARK: - Repo-map (Context Access Layer L5a)

/// A directed reference graph of project symbols. Each node is a symbol
/// (class, function, type) with its file path. Edges point from the
/// referencing file to the referenced symbol.
struct ReferenceGraph: Sendable {
    struct Node: Hashable, Sendable {
        let symbolName: String
        let filePath: String
        let kind: String
    }

    private(set) var nodes: Set<Node> = []
    private(set) var outgoingEdges: [Node: Set<Node>] = [:]
    private(set) var incomingEdges: [Node: Set<Node>] = [:]

    mutating func addNode(_ node: Node) {
        nodes.insert(node)
    }

    mutating func addEdge(from source: Node, to target: Node) {
        addNode(source)
        addNode(target)
        outgoingEdges[source, default: []].insert(target)
        incomingEdges[target, default: []].insert(source)
    }

    /// Standard PageRank with optional personalization toward chat context.
    /// Returns each node's rank normalized to sum = 1.0.
    func pageRank(iterations: Int = 20, dampingFactor: Double = 0.85, personalization: [Node: Double] = [:]) -> [Node: Double] {
        let count = nodes.count
        guard count > 0 else { return [:] }

        let initialRank = 1.0 / Double(count)
        var ranks: [Node: Double] = [:]
        for node in nodes {
            ranks[node] = initialRank
        }

        // Build personalization vector (uniform if empty)
        let personalizeSum = personalization.values.reduce(0, +)
        let personalizeVector: [Node: Double]
        if personalizeSum > 0 {
            personalizeVector = personalization.mapValues { $0 / personalizeSum }
        } else {
            personalizeVector = Dictionary(uniqueKeysWithValues: nodes.map { ($0, initialRank) })
        }

        for _ in 0..<iterations {
            var newRanks: [Node: Double] = [:]
            let danglingSum = nodes.filter { outgoingEdges[$0]?.isEmpty ?? true }.reduce(0.0) { $0 + ranks[$1, default: 0] }

            for node in nodes {
                let incomingSum = (incomingEdges[node] ?? []).reduce(0.0) { sum, source in
                    let outCount = Double(outgoingEdges[source]?.count ?? 1)
                    return sum + (ranks[source, default: 0] / outCount)
                }
                // Personalized PageRank: teleport according to personalization vector,
                // distribute dangling rank according to same vector.
                let teleportProb = personalizeVector[node, default: initialRank]
                let rank = (1.0 - dampingFactor) * teleportProb
                    + dampingFactor * (incomingSum + danglingSum * teleportProb)
                newRanks[node] = rank
            }

            ranks = newRanks
        }

        return ranks
    }
}

/// Builds a condensed repo-map (~1000 tokens) from the project's symbol graph.
/// The map is personalized toward files mentioned in the current chat context.
/// Results are cached per project root to avoid repeated full-project scans.
private actor MapCache {
    var cache: [String: String] = [:]
    var cacheAge: [String: Date] = [:]
    var accessOrder: [String] = []
    let maxAge: TimeInterval = 300
    let maxEntries: Int = 50

    func get(_ key: String) -> String? {
        guard let cached = cache[key], let age = cacheAge[key],
              Date().timeIntervalSince(age) < maxAge else { return nil }
        bumpAccess(key)
        return cached
    }

    func set(_ key: String, value: String) {
        if cache.count >= maxEntries && cache[key] == nil {
            if let oldest = accessOrder.first {
                cache.removeValue(forKey: oldest)
                cacheAge.removeValue(forKey: oldest)
                accessOrder.removeFirst()
            }
        }
        cache[key] = value
        cacheAge[key] = Date()
        bumpAccess(key)
    }

    private func bumpAccess(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    func invalidate(projectRoot: URL) {
        let prefix = projectRoot.standardizedFileURL.path
        cache = cache.filter { !$0.key.hasPrefix(prefix) }
        cacheAge = cacheAge.filter { !$0.key.hasPrefix(prefix) }
        accessOrder = accessOrder.filter { $0.hasPrefix(prefix) }
    }
}

enum RepoMapBuilder {
    private static let mapCache = MapCache()

    /// Retrieve the cached map for a project root, or build + cache it.
    static func cachedMap(projectRoot: URL, personalizeFilePaths: Set<String> = []) async throws -> String {
        let key = projectRoot.standardizedFileURL.path + "|" + personalizeFilePaths.sorted().joined(separator: ",")
        if let cached = await mapCache.get(key) {
            return cached
        }
        let map = try await buildMap(projectRoot: projectRoot, personalizeFilePaths: personalizeFilePaths)
        await mapCache.set(key, value: map)
        return map
    }

    /// Invalidate the cached map (e.g. after file changes).
    static func invalidateCache(projectRoot: URL) async {
        await mapCache.invalidate(projectRoot: projectRoot)
    }
    /// Quick count of source files — used to skip repo-map for large projects.
    static func fileCount(projectRoot: URL, fileManager: FileManager = .default) -> Int {
        let sourceFiles = collectSourceFiles(at: projectRoot, fileManager: fileManager)
        return sourceFiles.count
    }
    static let maxMapTokens = 1000
    /// Approximate token ratio for source text
    private static let charsPerToken = 4

    /// Build a repo-map for the given project. Scans source files, extracts
    /// symbols, builds a reference graph, ranks via PageRank, and formats
    /// a condensed text map.
    static func buildMap(
        projectRoot: URL,
        personalizeFilePaths: Set<String> = [],
        fileManager: FileManager = .default
    ) async throws -> String {
        let sourceFiles = collectSourceFiles(at: projectRoot, fileManager: fileManager)
        guard !sourceFiles.isEmpty else { return "(no source files found)" }

        // Phase 1: extract symbols from all files
        var symbolsByFile: [String: [ExtractedSymbol]] = [:]
        var allSymbolNames: [String: ReferenceGraph.Node] = [:] // name → canonical node
        var fileContentCache: [String: String] = [:]

        for url in sourceFiles {
            guard let content = try? String(contentsOf: url) else { continue }
            let path = url.path
            fileContentCache[path] = content
            let symbols = SymbolExtractor.extract(from: url, content: content)
            guard !symbols.isEmpty else { continue }
            symbolsByFile[path] = symbols
            for sym in symbols {
                let node = ReferenceGraph.Node(symbolName: sym.name, filePath: path, kind: sym.kind)
                let key = "\(sym.kind)::\(sym.name)::\(path)"
                if allSymbolNames[key] == nil {
                    allSymbolNames[key] = node
                }
            }
        }

        guard !allSymbolNames.isEmpty else { return "(no symbols found)" }

        // Phase 2: build reference graph by scanning each file for symbols from OTHER files
        var graph = ReferenceGraph()
        // Register all symbol nodes
        for node in allSymbolNames.values {
            graph.addNode(node)
        }

        // For each file, check which external symbols it references
        let allExternalSymbols = Array(allSymbolNames.values)
        for (filePath, content) in fileContentCache {
            // Create a file-level node representing this source file
            let fileNode = ReferenceGraph.Node(
                symbolName: "<file>",
                filePath: filePath,
                kind: "file"
            )
            graph.addNode(fileNode)

            let fileSymbols = Set(symbolsByFile[filePath]?.map { $0.name } ?? [])
            for extSym in allExternalSymbols where extSym.filePath != filePath {
                guard !fileSymbols.contains(extSym.symbolName) else { continue }
                guard content.contains(extSym.symbolName) else { continue }
                // Edge from this file TO the external symbol → "file depends on symbol"
                let targetNode = ReferenceGraph.Node(
                    symbolName: extSym.symbolName,
                    filePath: extSym.filePath,
                    kind: extSym.kind
                )
                graph.addEdge(from: fileNode, to: targetNode)
            }
        }

        // Phase 3: PageRank with personalization
        let personalization: [ReferenceGraph.Node: Double]
        if !personalizeFilePaths.isEmpty {
            personalization = Dictionary(uniqueKeysWithValues: graph.nodes.compactMap { node in
                personalizeFilePaths.contains(node.filePath) ? (node, 1.0) : nil
            })
        } else {
            personalization = [:]
        }

        let ranks = graph.pageRank(personalization: personalization)

        // Phase 4: format condensed map
        let rankedNodes = ranks.sorted { $0.value > $1.value }
        let maxChars = maxMapTokens * charsPerToken

        var output = "project symbol map (PageRank-ranked):\n"
        var usedChars = output.count

        for (node, rank) in rankedNodes {
            let fileShort = shortenPath(node.filePath, projectRoot: projectRoot)
            let line = "  \(node.kind) \(node.symbolName) — \(fileShort) [rank: \(String(format: "%.2f", rank))]\n"
            if usedChars + line.count > maxChars { break }
            output += line
            usedChars += line.count
        }

        return output
    }

    /// Walk the project directory collecting source files (excluding common non-source dirs).
    private static func collectSourceFiles(at root: URL, fileManager: FileManager) -> [URL] {
        let excludedDirs: Set<String> = [".ide", ".git", "node_modules", ".build", "DerivedData",
                                          ".build-tests", "Pods", "build", "dist", ".next"]
        let extensions: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "php",
                                        "kt", "java", "go", "rs", "rb", "c", "cpp", "h", "hpp"]

        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.hasDirectoryPath {
                if excludedDirs.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if extensions.contains(url.pathExtension) {
                files.append(url)
            }
        }
        return files
    }

    private static func shortenPath(_ fullPath: String, projectRoot: URL) -> String {
        let rootPath = projectRoot.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return fullPath }
        let relative = String(fullPath.dropFirst(rootPath.count + 1))
        return relative
    }
}
