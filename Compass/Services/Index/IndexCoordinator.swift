import Foundation
import Combine

/// Coordinates indexing operations for a project.
/// Uses an actor for thread-safe state management.
/// All indexing work runs on background threads via detached tasks.
public actor IndexCoordinator {
    private let eventBus: EventBusProtocol
    private let indexer: IndexerActor
    private let config: IndexConfiguration
    private let projectRoot: URL?
    private let activityCoordinator: (any AgentActivityCoordinating)?
    private let backgroundWorkGovernor: BackgroundWorkGovernor
    
    private var isEnabled: Bool
    private var reindexTask: Task<Void, Never>?
    private var singleFileTasks: [UUID: Task<Void, Never>] = [:]
    private var generation: UInt64 = 0
    
    // Bulk operation tracking
    private var recentFileChanges: [Date] = []
    private var bulkIndexTask: Task<Void, Never>?
    
    // Collector for URLs during debounce window — prevents dropping intermediate values
    private var pendingIndexURLs: Set<String> = []
    
    // Combine subscriptions must be managed on MainActor
    @MainActor private var cancellables = Set<AnyCancellable>()
    @MainActor private var debounceSubject = PassthroughSubject<URL, Never>()

    init(
        eventBus: EventBusProtocol,
        indexer: IndexerActor,
        config: IndexConfiguration = .default,
        projectRoot: URL? = nil,
        activityCoordinator: any AgentActivityCoordinating,
        backgroundWorkGovernor: BackgroundWorkGovernor
    ) {
        self.eventBus = eventBus
        self.indexer = indexer
        self.config = config
        self.isEnabled = config.enabled
        self.projectRoot = projectRoot?.standardizedFileURL
        self.activityCoordinator = activityCoordinator
        self.backgroundWorkGovernor = backgroundWorkGovernor

        // DO NOT start fire-and-forget tasks here!
        // Starting Task.detached or Task {} from actor init can cause
        // Swift actor isolation deadlocks when .value is accessed.
        // Instead, call start() explicitly after construction.
    }
    
    /// Must be called after construction to start background tasks
    /// This ensures all actor isolation is properly set up before spawning tasks
    public func start(projectRoot: URL) {
        Task.detached(priority: .utility) {
            await IndexLogger.shared.setup(projectRoot: projectRoot)
            await IndexLogger.shared.log("IndexCoordinator initialized with root: \(projectRoot.path)")
        }

        Task { @MainActor [weak self] in
            self?.setupSubscriptions()
        }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    public func stop() async {
        generation &+= 1
        isEnabled = false

        reindexTask?.cancel()
        reindexTask = nil

        for (_, task) in singleFileTasks {
            task.cancel()
        }
        singleFileTasks.removeAll()

        await MainActor.run {
            self.cancellables.removeAll()
        }
    }

    public func reindexProject(rootURL: URL) {
        guard isEnabled else {
            Task.detached(priority: .utility) { await IndexLogger.shared.log("Reindex skipped: Indexing is disabled") }
            return
        }

        generation &+= 1
        let localGeneration = generation
        reindexTask?.cancel()
        reindexTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performReindex(rootURL: rootURL, localGeneration: localGeneration)
        }
    }

    private func performReindex(rootURL: URL, localGeneration: UInt64) async {
        await backgroundWorkGovernor.waitUntilReady(
            for: .indexing,
            reason: "full_reindex:\(rootURL.lastPathComponent)"
        )
        guard !Task.isCancelled, localGeneration == generation else { return }

        // Wrap indexing with power management to prevent sleep during long operations
        if let coordinator = activityCoordinator {
            await coordinator.withActivity(type: .indexing) {
                await self.performReindexInternal(rootURL: rootURL, localGeneration: localGeneration)
            }
        } else {
            await performReindexInternal(rootURL: rootURL, localGeneration: localGeneration)
        }
    }
    
    private func performReindexInternal(rootURL: URL, localGeneration: UInt64) async {
        let start = Date()
        await IndexLogger.shared.log("Starting project reindex for: \(rootURL.path)")

        // Run file enumeration off main thread. Load the merged list fresh so
        // agent-added [custom] patterns (exclude_from_index tool) take effect
        // on the next reindex without reopening the project.
        let excludePatterns = IndexExcludePatternManager.loadExcludePatterns(
            projectRoot: rootURL,
            defaultPatterns: config.excludePatterns
        )
        let allFiles = await Task.detached(priority: .userInitiated) {
            IndexFileEnumerator.enumerateProjectFiles(
                rootURL: rootURL,
                excludePatterns: excludePatterns
            )
        }.value

        // Only index files with supported extensions
        let supportedExts = AppConstantsIndexing.indexableExtensions
        let files = allFiles.filter { supportedExts.contains($0.pathExtension.lowercased()) }
        let total = files.count
        await IndexLogger.shared.log("Found \(allFiles.count) project files (\(total) indexable)")

        // Clean up stale entries for files that no longer exist on disk
        await cleanupStaleEntries(files: files, rootURL: rootURL)

        // Check which files actually need work before publishing events
        let filesNeedingWork = await countFilesNeedingWork(files: files)

        // Only publish indexing events if there's actual work to do
        if filesNeedingWork > 0 {
            eventBus.publish(IndexingStartedEvent())
        }

        let processed = await processIndexFiles(files, total: total, localGeneration: localGeneration)

        if Task.isCancelled || localGeneration != generation { return }

        let duration = Date().timeIntervalSince(start)
        await IndexLogger.shared.log(
            "Reindex completed: \(processed)/\(total) files in " +
                "\(String(format: "%.2f", duration))s"
        )
        // Only publish completion events if we published start events
        if filesNeedingWork > 0 || processed > 0 {
            eventBus.publish(IndexingCompletedEvent(indexedCount: processed, duration: duration))
            eventBus.publish(ProjectReindexCompletedEvent(indexedCount: processed, duration: duration))
        }
    }

    private func processIndexFiles(_ files: [URL], total: Int, localGeneration: UInt64) async -> Int {
        // Wait once for background work conditions before processing all files
        await backgroundWorkGovernor.waitUntilReady(
            for: .indexing,
            reason: "reindex_batch:\(files.count)_files"
        )
        var processed = 0
        for file in files {
            if Task.isCancelled || localGeneration != generation { break }
            if !isEnabled {
                await IndexLogger.shared.log("Reindex aborted: Indexing was disabled during process")
                break
            }
            if Task.isCancelled || localGeneration != generation { break }
            await publishProgress(processed: processed, total: total, file: file)
            do {
                try await indexer.indexFile(at: file)
                processed += 1
            } catch {
                await IndexLogger.shared.log("Failed to index file \(file.path): \(error)")
                eventBus.publish(IndexingErrorEvent(
                    operation: "indexFile",
                    filePath: file.path,
                    error: error
                ))
            }
            await publishProgress(processed: processed, total: total, file: file)
        }
        return processed
    }

    private func publishProgress(processed: Int, total: Int, file: URL) async {
        eventBus.publish(
            IndexingProgressEvent(
                processedCount: processed,
                totalCount: total,
                currentFile: file
            )
        )
    }

    @MainActor
    private func setupSubscriptions() {
        setupFileEventSubscriptions()
        setupDebounceSubscription()
    }

    @MainActor
    private func setupFileEventSubscriptions() {
        setupFileCreatedSubscription()
        setupFileModifiedSubscription()
        setupFileRenamedSubscription()
        setupFileDeletedSubscription()
        setupExclusionsChangedSubscription()
    }

    /// Agent edits to the dynamic exclusion list (exclude_from_index) apply
    /// immediately: re-enumerate with the merged patterns and prune/reindex.
    @MainActor
    private func setupExclusionsChangedSubscription() {
        eventBus.subscribe(to: IndexExclusionsChangedEvent.self) { [weak self] event in
            Task { [weak self] in
                guard let self else { return }
                guard await self.isEnabled, let rootURL = await self.projectRoot else { return }
                await IndexLogger.shared.log(
                    "Index exclusions changed (+\(event.added.count) / -\(event.removed.count)) — re-enumerating"
                )
                await self.reindexProject(rootURL: rootURL)
            }
        }
        .store(in: &cancellables)
    }

    @MainActor
    private func setupFileCreatedSubscription() {
        eventBus.subscribe(to: FileCreatedEvent.self) { [weak self] event in
            Task { [weak self] in
                guard let self else { return }
                guard await self.isEnabled else { return }
                guard await self.isPathWithinProjectRoot(event.url) else { return }
                await self.debounceSubject.send(event.url)
            }
        }
        .store(in: &cancellables)
    }

    @MainActor
    private func setupFileModifiedSubscription() {
        eventBus.subscribe(to: FileModifiedEvent.self) { [weak self] event in
            Task { [weak self] in
                guard let self else { return }
                guard await self.isEnabled else { return }
                guard await self.isPathWithinProjectRoot(event.url) else { return }
                await self.debounceSubject.send(event.url)
            }
        }
        .store(in: &cancellables)
    }

    @MainActor
    private func setupFileRenamedSubscription() {
        eventBus.subscribe(to: FileRenamedEvent.self) { [weak self] event in
            Task { [weak self] in
                guard let self else { return }
                guard await self.isEnabled else { return }
                guard await self.isPathWithinProjectRoot(event.oldUrl), await self.isPathWithinProjectRoot(event.newUrl) else { return }
                try? await self.indexer.removeFile(at: event.oldUrl)
                await self.debounceSubject.send(event.newUrl)
            }
        }
        .store(in: &cancellables)
    }

    @MainActor
    private func setupFileDeletedSubscription() {
        eventBus.subscribe(to: FileDeletedEvent.self) { [weak self] event in
            Task { [weak self] in
                guard let self else { return }
                guard await self.isEnabled else { return }
                guard await self.isPathWithinProjectRoot(event.url) else { return }
                try? await self.indexer.removeFile(at: event.url)
            }
        }
        .store(in: &cancellables)
    }

    @MainActor
    private func setupDebounceSubscription() {
        // Collect all URLs into pendingIndexURLs as they arrive, then drain on debounce
        debounceSubject
            .debounce(for: .milliseconds(config.debounceMs), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.drainPendingIndexURLs()
                }
            }
            .store(in: &cancellables)
        
        // Also add each URL to pending set immediately (before debounce fires)
        debounceSubject
            .sink { [weak self] url in
                Task { [weak self] in
                    await self?.addPendingIndexURL(url)
                }
            }
            .store(in: &cancellables)
        
        // Bulk operation debounce - longer delay for batch operations like npm install
        debounceSubject
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.trackFileChange()
                }
            }
            .store(in: &cancellables)
    }
    
    private func addPendingIndexURL(_ url: URL) {
        pendingIndexURLs.insert(url.standardizedFileURL.path)
    }
    
    private func drainPendingIndexURLs() async {
        let paths = pendingIndexURLs
        pendingIndexURLs.removeAll()
        for path in paths {
            await indexFile(URL(fileURLWithPath: path))
        }
    }
    
    private func trackFileChange() async {
        let now = Date()
        recentFileChanges.append(now)
        
        // Clean up old entries (older than bulk operation debounce time)
        let cutoff = now.addingTimeInterval(-Double(config.bulkOperationDebounceMs) / 1000.0)
        recentFileChanges = recentFileChanges.filter { $0 > cutoff }
        
        // If we have too many changes, trigger bulk reindex
        if recentFileChanges.count >= config.bulkOperationThreshold {
            triggerBulkReindex()
        }
    }
    
    private func triggerBulkReindex() {
        guard let root = projectRoot else { return }
        
        bulkIndexTask?.cancel()
        bulkIndexTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // Wait for the debounce period to ensure all files are created
            try? await Task.sleep(nanoseconds: UInt64(self.config.bulkOperationDebounceMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            
            let changeCount = await self.recentFileChanges.count
            await IndexLogger.shared.log("Bulk file operation detected (\(changeCount) changes), triggering full reindex")
            await self.reindexProject(rootURL: root)
            await self.setRecentFileChanges([])
        }
    }
    
    private func setRecentFileChanges(_ changes: [Date]) {
        recentFileChanges = changes
    }

    private func indexFile(_ url: URL) async {
        guard await isPathWithinProjectRoot(url) else { return }
        let localGeneration = generation

        let id = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let enabled = await self.isEnabled
                guard enabled else {
                    await IndexLogger.shared.log("Single file index skipped for \(url.path): Indexing disabled")
                    return
                }
                await IndexLogger.shared.log("Indexing single file: \(url.path)")
                await self.eventBus.publish(IndexingStartedEvent())
                await self.eventBus.publish(IndexingProgressEvent(processedCount: 0, totalCount: 1, currentFile: url))
                let currentGen = await self.generation
                if Task.isCancelled || localGeneration != currentGen { return }
                try await self.indexer.indexFile(at: url)
                let currentGen2 = await self.generation
                if Task.isCancelled || localGeneration != currentGen2 { return }
                await self.eventBus.publish(IndexingProgressEvent(processedCount: 1, totalCount: 1, currentFile: url))
                await self.eventBus.publish(IndexingCompletedEvent(indexedCount: 1, duration: 0))
                await IndexLogger.shared.log("Successfully indexed single file: \(url.path)")
            } catch {
                await IndexLogger.shared.log("Failed to index file \(url.path): \(error)")
                await self.eventBus.publish(IndexingErrorEvent(
                    operation: "singleFileIndex",
                    filePath: url.path,
                    error: error
                ))
            }

            await self.removeSingleFileTask(id: id)
        }

        singleFileTasks[id] = task
    }
    
    private func removeSingleFileTask(id: UUID) {
        singleFileTasks[id] = nil
    }

    private func isPathWithinProjectRoot(_ url: URL) -> Bool {
        guard let projectRoot else { return true }
        let candidate = url.standardizedFileURL.path
        let rootPath = projectRoot.path
        return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
    }

    private func cleanupStaleEntries(files: [URL], rootURL: URL) async {
        let knownPaths = Set(files.map { $0.path })
        do {
            let removed = try await indexer.pruneResourcesNotInPaths(knownPaths)
            if removed > 0 {
                await IndexLogger.shared.log("Cleaned up \(removed) stale index entries for deleted files")
            }
        } catch {
            await IndexLogger.shared.log("Failed to clean up stale index entries: \(error)")
            eventBus.publish(IndexingErrorEvent(operation: "cleanupStaleEntries", error: error))
        }
    }

    private func countFilesNeedingWork(files: [URL]) async -> Int {
        var count = 0
        for file in files {
            let resourceId = file.absoluteString
            let fileModTime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
            guard let fileModTime else { count += 1; continue }
            let existingModTime = try? await indexer.getResourceLastModified(resourceId: resourceId)
            if let existingModTime, abs(existingModTime - fileModTime) < 0.001 {
                continue
            }
            count += 1
        }
        return count
    }
}
