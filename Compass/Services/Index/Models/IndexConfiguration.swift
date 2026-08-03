import Foundation

public struct IndexConfiguration: Codable, Sendable {
    public var enabled: Bool
    public var debounceMs: Int
    /// Debounce delay after last file change before triggering index (helps batch npm install, etc.)
    public var bulkOperationDebounceMs: Int
    /// Threshold of file changes that triggers immediate reindex instead of waiting
    public var bulkOperationThreshold: Int
    public var excludePatterns: [String]
    public var storageDirectoryPath: String?

    public init(
        enabled: Bool,
        debounceMs: Int,
        bulkOperationDebounceMs: Int = 5000,
        bulkOperationThreshold: Int = 50,
        excludePatterns: [String],
        storageDirectoryPath: String? = nil
    ) {
        self.enabled = enabled
        self.debounceMs = debounceMs
        self.bulkOperationDebounceMs = bulkOperationDebounceMs
        self.bulkOperationThreshold = bulkOperationThreshold
        self.excludePatterns = excludePatterns
        self.storageDirectoryPath = storageDirectoryPath
    }

    public static let `default` = IndexConfiguration(
        enabled: true,
        debounceMs: 300,
        // Debounce delay after last file change before triggering index (helps batch npm install, etc.)
        bulkOperationDebounceMs: 5000,
        // Threshold of file changes that triggers immediate reindex instead of waiting
        bulkOperationThreshold: 50,
        excludePatterns: [
            "*.generated.*",
            ".git/*",
            AppConstantsFileSystem.projectDirName,

            "node_modules",
            "bower_components",
            "jspm_packages",
            ".next",
            ".nuxt",
            ".svelte-kit",
            ".astro",
            ".vite",
            ".vercel",
            ".output",
            "dist",
            "build",
            "out",
            "coverage",
            ".nyc_output",
            ".cache",
            ".parcel-cache",
            ".turbo",
            ".webpack",
            ".rollup.cache",

            "Pods",
            "Carthage",
            ".build",
            "DerivedData",

            "vendor",
            "composer.lock",
            ".composer",

            "__pycache__",
            ".pytest_cache",
            ".mypy_cache",
            ".ruff_cache",
            ".venv",
            "venv",
            "env",

            "target",
            ".gradle",
            "buildSrc",
            "bin",
            "obj",
            ".idea",
            ".vscode",
            ".DS_Store"
        ],
        storageDirectoryPath: nil
    )
}
