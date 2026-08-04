import Foundation
import Combine

/// Subscribes to contextual data events and embeds content into the vector store.
/// Event-driven replacement for the FS-watching approach — content arrives
/// in-memory as typed structs, no file I/O, no debounce.
public actor VectorStoreEmbeddingCoordinator {
    private weak var vectorStoreService: VectorStoreService?
    private let eventBus: EventBusProtocol
    private let embedder: any MemoryEmbeddingGenerating
    private var bag: Set<AnyCancellable> = []

    /// Buffers the last user message per conversation for pairing with assistant responses.
    private var pendingQueries: [String: String] = [:]
    private var pendingQueriesOrder: [String] = []
    private static let maxPendingQueries = 100

    /// Debounced persistence — in-session additions must survive quit.
    private var saveTask: Task<Void, Never>?
    private static let saveDebounceNanoseconds: UInt64 = 5_000_000_000

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            guard !Task.isCancelled, let self else { return }
            try? await self.vectorStoreService?.save()
        }
    }

    public init(
        vectorStoreService: VectorStoreService,
        eventBus: EventBusProtocol,
        embedder: any MemoryEmbeddingGenerating
    ) {
        self.vectorStoreService = vectorStoreService
        self.eventBus = eventBus
        self.embedder = embedder
    }

    public func start() {
        let ctxHandler: @Sendable (ContextLogEvent) -> Void = { [weak self] event in
            Task { [weak self] in await self?.handleContextLog(event) }
        }
        eventBus.subscribe(to: ContextLogEvent.self, handler: ctxHandler).store(in: &bag)

        let toolHandler: @Sendable (ToolResultEvent) -> Void = { [weak self] event in
            Task { [weak self] in await self?.handleToolResult(event) }
        }
        eventBus.subscribe(to: ToolResultEvent.self, handler: toolHandler).store(in: &bag)
    }

    // MARK: - ContextLogEvent

    private func handleContextLog(_ event: ContextLogEvent) async {
        guard let convId = event.conversationId else { return }

        if event.source == "chat.user_message" {
            if pendingQueries[convId] == nil {
                pendingQueriesOrder.append(convId)
            }
            pendingQueries[convId] = event.content
            if pendingQueries.count > Self.maxPendingQueries, let oldest = pendingQueriesOrder.first {
                pendingQueriesOrder.removeFirst()
                pendingQueries.removeValue(forKey: oldest)
            }
        } else if event.source == "chat.assistant_message" || event.source == "chat.response" {
            guard let queryText = pendingQueries.removeValue(forKey: convId) else { return }
            pendingQueriesOrder.removeAll { $0 == convId }

            let qVec = (try? await embedder.generateEmbedding(for: queryText)) ?? []
            let rVec = (try? await embedder.generateEmbedding(for: event.content)) ?? []
            guard !qVec.isEmpty, !rVec.isEmpty else { return }

            // Text is stored inline: the conversation NDJSON is a heterogeneous
            // event stream (chat.*, tool.*, ...) so positional message indices
            // resolve to the wrong lines.
            try? await vectorStoreService?.addEntry(
                text: queryText,
                vector: qVec,
                source: "conversation",
                category: convId
            )
            try? await vectorStoreService?.addEntry(
                text: event.content,
                vector: rVec,
                source: "conversation",
                category: convId
            )
            scheduleSave()
        }
    }

    // MARK: - ToolResultEvent

    private func handleToolResult(_ event: ToolResultEvent) async {
        guard event.type == "execute_success" || event.type == "execute_error",
              let output = event.output, !output.isEmpty else { return }

        let text = "Tool \(event.toolName): \(output)"
        let vec = (try? await embedder.generateEmbedding(for: text)) ?? []
        guard !vec.isEmpty else { return }

        try? await vectorStoreService?.addEntry(
            text: String(text.prefix(500)),
            vector: vec,
            source: event.toolName,
            category: event.conversationId
        )
        scheduleSave()
    }

    deinit {
        saveTask?.cancel()
    }
}
