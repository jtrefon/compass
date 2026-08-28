import Foundation

@MainActor
final class ConversationToolProvider {
    private let fileSystemService: FileSystemService
    private let eventBus: EventBusProtocol
    private var vectorStoreService: VectorStoreService?
    private var embedder: (any MemoryEmbeddingGenerating)?

    private let codebaseIndexProvider: () -> CodebaseIndexProtocol?
    private let projectRootProvider: () -> URL?

    init(
        fileSystemService: FileSystemService,
        eventBus: EventBusProtocol,
        vectorStoreService: VectorStoreService?,
        embedder: (any MemoryEmbeddingGenerating)?,
        codebaseIndexProvider: @escaping () -> CodebaseIndexProtocol?,
        projectRootProvider: @escaping () -> URL?
    ) {
        self.fileSystemService = fileSystemService
        self.eventBus = eventBus
        self.vectorStoreService = vectorStoreService
        self.embedder = embedder
        self.codebaseIndexProvider = codebaseIndexProvider
        self.projectRootProvider = projectRootProvider
    }

    func updateVectorStoreService(_ service: VectorStoreService?) {
        vectorStoreService = service
    }

    func updateEmbedder(_ embedder: (any MemoryEmbeddingGenerating)?) {
        self.embedder = embedder
    }

    func availableTools(mode: AIMode, pathValidator: PathValidator) -> [AITool] {
        return mode.allowedTools(from: allTools(pathValidator: pathValidator))
    }

    func allTools(pathValidator: PathValidator) -> [AITool] {
        guard let projectRoot = projectRootProvider() else { return [] }
        
        var tools: [AITool] = []

        // Core Filesystem — surgical, guarded via PathValidator + ToolScheduler
        tools.append(ReadFileTool(fileSystemService: fileSystemService, pathValidator: pathValidator))
        tools.append(WriteFileTool(fileSystemService: fileSystemService, pathValidator: pathValidator, eventBus: eventBus))
        tools.append(PatchFileToolAdapter(projectRoot: projectRoot))
        tools.append(DeleteFileTool(pathValidator: pathValidator, eventBus: eventBus))

        // Search — rg + tree-sitter surgical ranges (replaces ls/glob)
        tools.append(SearchProjectTool(index: codebaseIndexProvider(), projectRoot: projectRoot))

        // Web — URLSession fetch (WebKit window retired)
        tools.append(GoogleWebSearchTool())
        tools.append(WebBrowseTool())

        // Context — gated curated RAG (only when COMPASS_ENABLE_RAG=1)
        if Self.isRAGEnabled {
            tools.append(ContextTool(vectorStoreService: vectorStoreService, embedder: embedder))
        }

        // Terminal — the escape hatch (project-root cwd, sessioned)
        tools.append(RunCommandTool(projectRoot: projectRoot, pathValidator: pathValidator))

        // Planning — runner-driven closed loop (not a model tool during execution)
        // PlanTool remains for init/breakOut only; per-item loop is driven by GraphRunner
        tools.append(PlanTool())

        return tools
    }

    private static var isRAGEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        let raw = env["COMPASS_ENABLE_RAG"] ?? env["TEST_RUNNER_ENV_COMPASS_ENABLE_RAG"]
        if raw == "1" || raw?.lowercased() == "true" { return true }
        return false
    }
}
