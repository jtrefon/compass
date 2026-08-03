import Foundation

final class PromptRepository: @unchecked Sendable {
    static let shared = PromptRepository()

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prompt(
        key: String,
        projectRoot: URL?
    ) throws -> String {
        guard let url = resolvePromptURL(key: key, projectRoot: projectRoot) else {
            let environment = ProcessInfo.processInfo.environment
            let promptRoot = environment["COMPASS_PROMPTS_ROOT"] ?? "<unset>"
            let testRunnerPromptRoot = environment["TEST_RUNNER_ENV_COMPASS_PROMPTS_ROOT"] ?? "<unset>"
            let projectRootPath = projectRoot?.path ?? "<nil>"
            let currentDirectory = fileManager.currentDirectoryPath
            throw AppError.promptLoadingFailed(
                "Prompt file not found for key '\(key)'. Expected path segment: Prompts/\(key).md. " +
                "projectRoot=\(projectRootPath), cwd=\(currentDirectory), " +
                "COMPASS_PROMPTS_ROOT=\(promptRoot), " +
                "TEST_RUNNER_ENV_COMPASS_PROMPTS_ROOT=\(testRunnerPromptRoot)"
            )
        }

        return try loadPromptText(from: url, key: key)
    }

    func fallbackPrompt(
        key: String,
        defaultValue: String,
        allowFallback: Bool,
        projectRoot: URL?
    ) throws -> String {
        guard let url = resolvePromptURL(key: key, projectRoot: projectRoot) else {
            if allowFallback {
                return defaultValue
            }
            let environment = ProcessInfo.processInfo.environment
            let promptRoot = environment["COMPASS_PROMPTS_ROOT"] ?? "<unset>"
            let testRunnerPromptRoot = environment["TEST_RUNNER_ENV_COMPASS_PROMPTS_ROOT"] ?? "<unset>"
            let projectRootPath = projectRoot?.path ?? "<nil>"
            let currentDirectory = fileManager.currentDirectoryPath
            throw AppError.promptLoadingFailed(
                "Prompt file not found for key '\(key)'. Expected path segment: Prompts/\(key).md. " +
                "projectRoot=\(projectRootPath), cwd=\(currentDirectory), " +
                "COMPASS_PROMPTS_ROOT=\(promptRoot), " +
                "TEST_RUNNER_ENV_COMPASS_PROMPTS_ROOT=\(testRunnerPromptRoot)"
            )
        }

        do {
            return try loadPromptText(from: url, key: key)
        } catch {
            if allowFallback {
                return defaultValue
            }
            throw error
        }
    }

    private func loadPromptText(from url: URL, key: String) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw AppError.promptLoadingFailed(
                "Failed to read prompt file for key '\(key)' at path '\(url.path)'"
            )
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.promptLoadingFailed(
                "Prompt file is empty for key '\(key)' at path '\(url.path)'"
            )
        }

        return trimmed
    }

    private func resolvePromptURL(key: String, projectRoot: URL?) -> URL? {
        let relativePath = "Prompts/\(key).md"

        if let projectRoot {
            let direct = projectRoot.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: direct.path) {
                return direct
            }

            if let resolved = searchUpwardsForPromptsFolder(from: projectRoot, key: key) {
                return resolved
            }
        }

        let environment = ProcessInfo.processInfo.environment
        let promptRoots = [
            environment["COMPASS_PROMPTS_ROOT"],
            environment["TEST_RUNNER_ENV_COMPASS_PROMPTS_ROOT"]
        ]
        for root in promptRoots {
            guard let root, !root.isEmpty else { continue }
            let envURL = URL(fileURLWithPath: root, isDirectory: true)
            let candidate = envURL.appendingPathComponent("\(key).md")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        if let resolved = searchUpwardsForPromptsFolder(from: cwd, key: key) {
            return resolved
        }

        let bundleCandidates = [
            Bundle.main.bundleURL,
            Bundle(for: PromptRepository.self).bundleURL
        ]
        for bundleURL in bundleCandidates {
            if let resolved = searchUpwardsForPromptsFolder(from: bundleURL, key: key) {
                return resolved
            }
        }

        if let resolved = searchFromSourceRoot(key: key) {
            return resolved
        }

        return nil
    }

    private func searchFromSourceRoot(key: String) -> URL? {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        return searchUpwardsForPromptsFolder(from: sourceFileURL, key: key)
    }

    private func searchUpwardsForPromptsFolder(from start: URL, key: String) -> URL? {
        var current = start
        for _ in 0..<12 {
            let promptsFolder = current.appendingPathComponent("Prompts", isDirectory: true)
            if fileManager.fileExists(atPath: promptsFolder.path) {
                let candidate = promptsFolder.appendingPathComponent("\(key).md")
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return nil
    }
}
