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
        mode.allowedTools(from: allTools(pathValidator: pathValidator))
    }

    func allTools(pathValidator: PathValidator) -> [AITool] {
        guard let projectRoot = projectRootProvider() else { return [] }
        
        var tools: [AITool] = []

        // Core Filesystem Tools
        tools.append(ReadFileTool(fileSystemService: fileSystemService, pathValidator: pathValidator))
        tools.append(ListFilesTool(pathValidator: pathValidator))
        tools.append(WriteFileTool(fileSystemService: fileSystemService, pathValidator: pathValidator, eventBus: eventBus))
        tools.append(PatchFileToolAdapter(projectRoot: projectRoot))
        tools.append(DeleteFileTool(pathValidator: pathValidator, eventBus: eventBus))
        
        // Pinned Rules Tools
        tools.append(PinnedRuleAddTool(projectRoot: projectRoot))
        tools.append(PinnedRuleRemoveTool(projectRoot: projectRoot))
        tools.append(PinnedRuleListTool(projectRoot: projectRoot))

        // Context / Memory Tools
        tools.append(ContextTool(vectorStoreService: vectorStoreService, embedder: embedder))

        // Index hygiene — agent maintains the dynamic exclusion list
        tools.append(IndexExclusionTool(projectRoot: projectRoot))

        // Search & Structure Tools
        tools.append(SearchProjectTool(index: codebaseIndexProvider(), projectRoot: projectRoot))
        tools.append(GoogleWebSearchTool())
        tools.append(WebBrowseTool())
        tools.append(FindFileTool(pathValidator: pathValidator))

        // Terminal & Execution
        tools.append(RunCommandTool(projectRoot: projectRoot, pathValidator: pathValidator))

        // Planning & Task Management
        tools.append(PlanTool())

        return tools
    }
}
