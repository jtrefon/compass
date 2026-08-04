import Foundation
import Combine

@MainActor
final class UnifiedLintingFramework {
    struct LintCacheEntry {
        let lastModifiedDate: Date
        let diagnostics: [Diagnostic]
    }

    private let eventBus: EventBusProtocol
    private let diagnosticsStore: DiagnosticsStore
    private let workspaceRootProvider: () -> URL?
    private let languageModuleManager: LanguageModuleManager
    private var lintCacheByAbsolutePath: [String: LintCacheEntry] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var isProjectScanRunning = false

    init(
        eventBus: EventBusProtocol,
        diagnosticsStore: DiagnosticsStore,
        languageModuleManager: LanguageModuleManager,
        workspaceRootProvider: @escaping () -> URL?
    ) {
        self.eventBus = eventBus
        self.diagnosticsStore = diagnosticsStore
        self.languageModuleManager = languageModuleManager
        self.workspaceRootProvider = workspaceRootProvider
        subscribeToEvents()
    }

    func runProjectScanIfNeeded() {
        guard !isProjectScanRunning else { return }
        guard let rootURL = workspaceRootProvider()?.standardizedFileURL else { return }

        isProjectScanRunning = true
        Task { [weak self] in
            guard let self else { return }
            let files = self.collectLintableFiles(in: rootURL)
            var aggregate: [Diagnostic] = []
            for fileURL in files {
                let diagnostics = self.lintFileIfNeeded(fileURL)
                aggregate.append(contentsOf: diagnostics)
            }
            self.diagnosticsStore.replace(with: aggregate)
            self.isProjectScanRunning = false
        }
    }

    private func subscribeToEvents() {
        eventBus.subscribe(to: FileOpenedEvent.self) { [weak self] event in
            guard let self else { return }
            let fileDiagnostics = self.lintFile(at: event.url, contentOverride: event.content)
            if let relativePath = self.relativePath(for: event.url) {
                self.diagnosticsStore.upsert(fileDiagnostics, replacingPath: relativePath)
            }
        }.store(in: &subscriptions)

        eventBus.subscribe(to: FileModifiedEvent.self) { [weak self] event in
            guard let self else { return }
            let fileDiagnostics = self.lintFile(at: event.url, contentOverride: nil)
            if let relativePath = self.relativePath(for: event.url) {
                self.diagnosticsStore.upsert(fileDiagnostics, replacingPath: relativePath)
            }
        }.store(in: &subscriptions)
    }

    private func collectLintableFiles(in rootURL: URL) -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            guard isLintableFile(next) else { continue }
            files.append(next)
        }
        return files
    }

    private func isLintableFile(_ fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        guard let module = languageModuleManager.getModule(forExtension: ext) else { return false }
        guard languageModuleManager.isEnabled(module.id) else { return false }
        guard languageModuleManager.isCapabilityEnabled(.lint, for: module.id) else { return false }
        return true
    }

    private func lintFileIfNeeded(_ fileURL: URL) -> [Diagnostic] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let lastModified = attributes?[.modificationDate] as? Date ?? .distantPast

        if let cached = lintCacheByAbsolutePath[fileURL.path], cached.lastModifiedDate == lastModified {
            return cached.diagnostics
        }

        return lintFile(at: fileURL, contentOverride: nil)
    }

    private func lintFile(at fileURL: URL, contentOverride: String?) -> [Diagnostic] {
        guard isLintableFile(fileURL) else { return [] }
        guard let language = language(for: fileURL) else { return [] }

        let content: String
        if let contentOverride {
            content = contentOverride
        } else {
            guard let loaded = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            content = loaded
        }

        let diagnostics = runBuiltinRules(
            content: content,
            relativePath: relativePath(for: fileURL) ?? fileURL.lastPathComponent
        )

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let lastModified = attributes?[.modificationDate] as? Date ?? .distantPast
        lintCacheByAbsolutePath[fileURL.path] = LintCacheEntry(lastModifiedDate: lastModified, diagnostics: diagnostics)
        return diagnostics
    }

    private func language(for fileURL: URL) -> CodeLanguage? {
        let ext = fileURL.pathExtension.lowercased()
        return languageModuleManager.getModule(forExtension: ext)?.id
    }

    private func relativePath(for fileURL: URL) -> String? {
        guard let rootURL = workspaceRootProvider()?.standardizedFileURL else { return nil }
        let rel = fileURL.relativeTo(rootURL)
        guard rel != fileURL.standardizedFileURL.path else { return nil }
        return rel
    }

    private func runBuiltinRules(content: String, relativePath: String) -> [Diagnostic] {
        []
    }

    private func severity(from value: String) -> DiagnosticSeverity {
        value.lowercased() == "error" ? .error : .warning
    }

    private func findLineLengthIssues(
        lines: [String],
        max: Int,
        path: String,
        severity: DiagnosticSeverity,
        message: String
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        for (index, line) in lines.enumerated() where line.count > max {
            diagnostics.append(
                Diagnostic(
                    relativePath: path,
                    line: index + 1,
                    column: max + 1,
                    severity: severity,
                    message: message
                )
            )
        }
        return diagnostics
    }

    private func findTrailingWhitespaceIssues(
        lines: [String],
        path: String,
        severity: DiagnosticSeverity,
        message: String
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        for (index, line) in lines.enumerated() {
            guard line.last?.isWhitespace == true else { continue }
            diagnostics.append(
                Diagnostic(
                    relativePath: path,
                    line: index + 1,
                    column: max(1, line.count),
                    severity: severity,
                    message: message
                )
            )
        }
        return diagnostics
    }
}
