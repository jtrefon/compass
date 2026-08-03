import Foundation

enum AppConstantsIndexing {
    /// Extensions the SQLite indexer actually extracts symbols for. Single
    /// source of truth — `IndexerActor` and `IndexCoordinator` both filter on
    /// this set (they previously maintained private copies that could drift).
    static let indexableExtensions: Set<String> = [
        "swift", "js", "jsx", "mjs", "ts", "tsx", "py", "php",
    ]
    static let allowedExtensions: Set<String> = [
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte",
        "py", "pyw",
        "php", "phtml",
        "cs", "vb", "fs", "razor", "cshtml", "aspx", "ascx", "master",
        "rb",
        "go",
        "rs",
        "java", "kt", "scala",
        "html", "css", "scss", "less",
        "json", "yaml", "yml", "toml",
        "md", "markdown",
        "sql",
        "sh", "bash",
    ]
    static let aiEnrichableExtensions: Set<String> = [
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte",
        "py", "pyw",
        "php", "phtml",
        "cs", "vb", "fs",
        "rb",
        "go",
        "rs",
        "java", "kt", "scala",
        "html", "css", "scss", "less",
    ]
}
