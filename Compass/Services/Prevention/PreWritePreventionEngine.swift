import Foundation

public enum PreventionFindingType: String, Sendable {
    case duplicateImpl = "duplicate_impl"
    case deadCodeRisk = "dead_code_risk"
    case parallelPathRisk = "parallel_path_risk"
    case orphanAPI = "orphan_api"
}

public enum PreventionSeverity: String, Sendable {
    case info
    case warning
    case critical
}

public struct PreventionFinding: Sendable {
    public let findingType: PreventionFindingType
    public let severity: PreventionSeverity
    public let candidateFileSpan: String
    public let existingFileSpans: [String]
    public let explanation: String
    public let blockRecommended: Bool

    public init(
        findingType: PreventionFindingType,
        severity: PreventionSeverity,
        candidateFileSpan: String,
        existingFileSpans: [String],
        explanation: String,
        blockRecommended: Bool
    ) {
        self.findingType = findingType
        self.severity = severity
        self.candidateFileSpan = candidateFileSpan
        self.existingFileSpans = existingFileSpans
        self.explanation = explanation
        self.blockRecommended = blockRecommended
    }
}

public enum PreventionPolicyOutcome: String, Sendable {
    case pass
    case warn
    case block
}

public struct PreventionCheckResult: Sendable {
    public let outcome: PreventionPolicyOutcome
    public let findings: [PreventionFinding]
    public let duplicateRiskCount: Int
    public let deadCodeRiskCount: Int

    public init(outcome: PreventionPolicyOutcome, findings: [PreventionFinding]) {
        self.outcome = outcome
        self.findings = findings
        self.duplicateRiskCount = findings.filter { $0.findingType == .duplicateImpl }.count
        self.deadCodeRiskCount = findings.filter { $0.findingType == .deadCodeRisk }.count
    }

    public var summary: String {
        if findings.isEmpty {
            return "No prevention findings."
        }

        return findings.map { finding in
            "[\(finding.severity.rawValue)] \(finding.findingType.rawValue): \(finding.explanation)"
        }.joined(separator: "\n")
    }
}

struct PreWritePreventionEngine {
    private let fileSystemService: FileSystemService
    private var projectRoot: URL

    init(fileSystemService: FileSystemService, projectRoot: URL) {
        self.fileSystemService = fileSystemService
        self.projectRoot = projectRoot
    }

    mutating func updateProjectRoot(_ newRoot: URL) {
        projectRoot = newRoot
    }

    func check(
        toolName: String,
        arguments: [String: Any],
        allowOverride: Bool
    ) -> PreventionCheckResult {
        let writes = candidateWrites(toolName: toolName, arguments: arguments)
        guard !writes.isEmpty else {
            return PreventionCheckResult(outcome: .pass, findings: [])
        }

        var findings: [PreventionFinding] = []
        findings.append(contentsOf: duplicateFindings(for: writes))
        findings.append(contentsOf: deadCodeFindings(for: writes))

        let shouldBlock = findings.contains { finding in
            finding.blockRecommended && finding.severity == .critical
        }

        let outcome: PreventionPolicyOutcome
        if shouldBlock && !allowOverride {
            outcome = .block
        } else if findings.isEmpty {
            outcome = .pass
        } else {
            outcome = .warn
        }

        return PreventionCheckResult(outcome: outcome, findings: findings)
    }

    private func duplicateFindings(for writes: [CandidateWrite]) -> [PreventionFinding] {
        var findings: [PreventionFinding] = []
        let existingFiles = projectTextFiles()

        for write in writes {
            if write.isNewFile, FileManager.default.fileExists(atPath: write.fileURL.path) {
                findings.append(
                    PreventionFinding(
                        findingType: .duplicateImpl,
                        severity: .critical,
                        candidateFileSpan: write.relativePath,
                        existingFileSpans: [write.relativePath],
                        explanation: "Target path already exists. Reuse or edit the existing file instead of creating a duplicate path.",
                        blockRecommended: true
                    )
                )
            }

            guard let content = write.content, !content.isEmpty else { continue }
            let normalizedCandidate = normalize(content)

            let exactDuplicatePaths = existingFiles.compactMap { existingURL -> String? in
                if existingURL.standardizedFileURL == write.fileURL.standardizedFileURL {
                    return nil
                }
                guard let existingContent = try? fileSystemService.readFile(at: existingURL) else { return nil }
                return normalize(existingContent) == normalizedCandidate
                    ? relativePath(for: existingURL)
                    : nil
            }

            if !exactDuplicatePaths.isEmpty {
                let shouldBlockExactDuplicate = shouldBlockExactDuplicateWrite(write: write)
                findings.append(
                    PreventionFinding(
                        findingType: .duplicateImpl,
                        severity: shouldBlockExactDuplicate ? .critical : .warning,
                        candidateFileSpan: write.relativePath,
                        existingFileSpans: exactDuplicatePaths,
                        explanation: shouldBlockExactDuplicate
                            ? "Generated content is an exact duplicate of existing implementation. Extend existing code instead."
                            : "Generated content matches an existing non-implementation artifact. Confirm whether a duplicated output file is intentional.",
                        blockRecommended: shouldBlockExactDuplicate
                    )
                )
                continue
            }

            let symbolNames = declarationSymbols(from: content)
            let collisions = declarationCollisions(symbolNames: symbolNames, excluding: write.fileURL)
            if !collisions.isEmpty {
                findings.append(
                    PreventionFinding(
                        findingType: .duplicateImpl,
                        severity: .warning,
                        candidateFileSpan: write.relativePath,
                        existingFileSpans: collisions,
                        explanation: "Potential duplicate implementation symbols detected. Validate extension points before adding a parallel path.",
                        blockRecommended: false
                    )
                )
            }
        }

        return findings
    }

    private func deadCodeFindings(for writes: [CandidateWrite]) -> [PreventionFinding] {
        var findings: [PreventionFinding] = []
        let existingFiles = projectTextFiles()

        for write in writes where write.isNewFile {
            if write.relativePath.lowercased().contains("tmp") || write.relativePath.lowercased().contains("draft") {
                findings.append(
                    PreventionFinding(
                        findingType: .deadCodeRisk,
                        severity: .warning,
                        candidateFileSpan: write.relativePath,
                        existingFileSpans: [],
                        explanation: "New file path suggests temporary or draft implementation. Confirm production linkage.",
                        blockRecommended: false
                    )
                )
            }

            guard let content = write.content, !content.isEmpty else { continue }
            let symbols = declarationSymbols(from: content)
            guard !symbols.isEmpty else { continue }

            let orphanSymbols = symbols.filter { symbol in
                !hasInboundReference(symbol: symbol, files: existingFiles, excluding: write.fileURL)
            }

            if !orphanSymbols.isEmpty {
                findings.append(
                    PreventionFinding(
                        findingType: .deadCodeRisk,
                        severity: .warning,
                        candidateFileSpan: write.relativePath,
                        existingFileSpans: [],
                        explanation: "New symbols appear unreferenced in existing flow: \(orphanSymbols.joined(separator: ", ")).",
                        blockRecommended: false
                    )
                )
            }
        }

        return findings
    }

    private func declarationCollisions(symbolNames: [String], excluding excludedURL: URL) -> [String] {
        guard !symbolNames.isEmpty else { return [] }

        var collisions: Set<String> = []
        let files = projectTextFiles().filter { $0.standardizedFileURL != excludedURL.standardizedFileURL }

        for fileURL in files {
            guard fileURL.pathExtension.lowercased() == "swift",
                  let content = try? fileSystemService.readFile(at: fileURL) else { continue }

            for symbol in symbolNames {
                if declares(symbol: symbol, in: content) {
                    collisions.insert(relativePath(for: fileURL))
                }
            }
        }

        return collisions.sorted()
    }

    private func hasInboundReference(symbol: String, files: [URL], excluding excludedURL: URL) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b") else {
            return false
        }

        for fileURL in files where fileURL.standardizedFileURL != excludedURL.standardizedFileURL {
            guard let content = try? fileSystemService.readFile(at: fileURL) else { continue }
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            if regex.firstMatch(in: content, range: range) != nil {
                return true
            }
        }

        return false
    }

    private func declares(symbol: String, in content: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        let pattern = "\\b(class|struct|enum|protocol|actor|func)\\s+\(escaped)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.firstMatch(in: content, range: range) != nil
    }

    private func declarationSymbols(from content: String) -> [String] {
        let pattern = "\\b(class|struct|enum|protocol|actor|func)\\s+([A-Za-z_][A-Za-z0-9_]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, range: range)
        var names: [String] = []
        names.reserveCapacity(matches.count)

        for match in matches {
            guard match.numberOfRanges > 2,
                  let nameRange = Range(match.range(at: 2), in: content) else {
                continue
            }
            names.append(String(content[nameRange]))
        }

        return Array(Set(names)).sorted()
    }

    private func candidateWrites(toolName: String, arguments: [String: Any]) -> [CandidateWrite] {
        switch toolName {
        case "write", "write_file", "create_file":
            guard let path = arguments["path"] as? String else { return [] }
            let resolvedURL = resolve(path: path)
            let content = arguments["content"] as? String
            let isNew = !FileManager.default.fileExists(atPath: resolvedURL.path)
            return [CandidateWrite(fileURL: resolvedURL, relativePath: relativePath(for: resolvedURL), content: content, isNewFile: isNew)]
        case "write_files":
            guard let files = arguments["files"] as? [[String: Any]] else { return [] }
            return files.compactMap { file in
                guard let path = file["path"] as? String else { return nil }
                let resolvedURL = resolve(path: path)
                let content = file["content"] as? String
                let isNew = !FileManager.default.fileExists(atPath: resolvedURL.path)
                return CandidateWrite(fileURL: resolvedURL, relativePath: relativePath(for: resolvedURL), content: content, isNewFile: isNew)
            }
        case "edit", "replace_in_file":
            guard let path = arguments["path"] as? String else { return [] }
            let resolvedURL = resolve(path: path)
            guard let oldText = arguments["old_text"] as? String,
                  let newText = arguments["new_text"] as? String,
                  let existing = try? fileSystemService.readFile(at: resolvedURL) else {
                return []
            }
            let newContent = existing.replacingOccurrences(of: oldText, with: newText)
            return [CandidateWrite(fileURL: resolvedURL, relativePath: relativePath(for: resolvedURL), content: newContent, isNewFile: false)]
        default:
            return []
        }
    }

    private func resolve(path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: trimmed).standardizedFileURL
            if absolute.path.hasPrefix(projectRoot.standardizedFileURL.path + "/") {
                return absolute
            }
            let relative = String(trimmed.dropFirst())
            return projectRoot.appendingPathComponent(relative).standardizedFileURL
        }

        return projectRoot.appendingPathComponent(trimmed).standardizedFileURL
    }

    private func relativePath(for url: URL) -> String {
        url.relativeTo(projectRoot)
    }

    private func projectTextFiles() -> [URL] {
        let allowedExtensions: Set<String> = ["swift", "md", "txt", "json", "yaml", "yml", "plist"]
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                continue
            }
            if allowedExtensions.contains(fileURL.pathExtension.lowercased()) {
                files.append(fileURL)
            }
        }
        return files
    }

    private func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private func shouldBlockExactDuplicateWrite(write: CandidateWrite) -> Bool {
        let implementationExtensions: Set<String> = [
            "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs",
            "py", "rb", "java", "kt", "go", "rs", "php",
            "c", "cc", "cpp", "cxx", "h", "hpp", "hh",
            "cs", "scala", "sh", "bash", "zsh",
            "css", "scss", "sass", "less", "html", "htm",
            "vue", "svelte"
        ]

        return implementationExtensions.contains(write.fileURL.pathExtension.lowercased())
    }
}

private struct CandidateWrite {
    let fileURL: URL
    let relativePath: String
    let content: String?
    let isNewFile: Bool
}
