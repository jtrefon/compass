import Foundation
import CoreServices

private final class ProjectRootFileWatcherCallbackBox {
    weak var watcher: ProjectRootFileWatcherActor?

    init(watcher: ProjectRootFileWatcherActor) {
        self.watcher = watcher
    }
}

/// Single FSEvent-based file watcher monitoring the project root.
///
/// Uses FSEvent flags for change detection (create/modify/delete) rather than
/// O(n) full-snapshot diffs. Events are debounced at 100ms then fanned out
/// via EventBus — the one source all consumers (editor reload, file tree,
/// indexing) subscribe to.
actor ProjectRootFileWatcherActor {
    private let rootURL: URL
    private let eventBus: EventBusProtocol
    private let excludePatterns: [String]

    private var stream: FSEventStreamRef?
    private var isActive = false
    private var callbackBox: ProjectRootFileWatcherCallbackBox?

    private var pendingCreated = Set<String>()
    private var pendingModified = Set<String>()
    private var pendingDeleted = Set<String>()
    private var flushTask: Task<Void, Never>?

    private var lastKnownModDates: [String: Date] = [:]

    private static func isIDEConfigPath(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        return normalized.contains("/\(AppConstantsFileSystem.projectDirName)/") || normalized.hasSuffix("/\(AppConstantsFileSystem.projectDirName)")
    }

    init(
        rootURL: URL,
        eventBus: EventBusProtocol,
        excludePatterns: [String]
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.eventBus = eventBus
        self.excludePatterns = excludePatterns
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        startWatching()
    }

    private func startWatching() {
        let path = rootURL.path as CFString
        let pathsToWatch = [path] as CFArray
        let callbackBox = ProjectRootFileWatcherCallbackBox(watcher: self)
        self.callbackBox = callbackBox

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(callbackBox).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<ProjectRootFileWatcherCallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds in
            guard let clientCallBackInfo else { return }
            let callbackBox = Unmanaged<ProjectRootFileWatcherCallbackBox>
                .fromOpaque(clientCallBackInfo)
                .takeUnretainedValue()
            guard let watcher = callbackBox.watcher else { return }

            var created = Set<String>()
            var modified = Set<String>()
            var deleted = Set<String>()

            let pathsArray: CFArray = unsafeBitCast(eventPaths, to: CFArray.self)
            for i in 0..<numEvents {
                let rawPath = unsafeBitCast(CFArrayGetValueAtIndex(pathsArray, i), to: CFString.self) as String
                let flags = eventFlags[i]

                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                    continue
                }

                let isCreated = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
                let isModified = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0
                let isRemoved = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0
                let isRenamed = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0

                if isCreated || (isRenamed && !isRemoved) {
                    created.insert(rawPath)
                } else if isRemoved || (isRenamed && !isCreated) {
                    deleted.insert(rawPath)
                } else if isModified {
                    modified.insert(rawPath)
                }
            }

            guard !created.isEmpty || !modified.isEmpty || !deleted.isEmpty else { return }
            Task { await watcher.enqueueChanges(created: created, modified: modified, deleted: deleted) }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            self.callbackBox = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard isActive else { return }
        isActive = false

        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        callbackBox = nil
        flushTask?.cancel()
        flushTask = nil
    }

    private func enqueueChanges(created: Set<String>, modified: Set<String>, deleted: Set<String>) {
        pendingCreated.formUnion(created)
        pendingModified.formUnion(modified)
        pendingDeleted.formUnion(deleted)

        let overlap = pendingCreated.intersection(pendingDeleted)
        if !overlap.isEmpty {
            pendingCreated.subtract(overlap)
            pendingDeleted.subtract(overlap)
        }

        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushChanges()
        }
    }

    private func flushChanges() {
        pendingCreated = []
        pendingModified = []
        pendingDeleted = []
        flushTask = nil

        var actualModifications = Set<String>()
        for path in pendingModified {
            if Self.isIDEConfigPath(path) {
                eventBus.publish(IDEFileModifiedEvent(url: URL(fileURLWithPath: path)))
                continue
            }
            let url = URL(fileURLWithPath: path)
            let currentMod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let currentMod, lastKnownModDates[path] != currentMod {
                lastKnownModDates[path] = currentMod
                actualModifications.insert(path)
            }
        }

        var nonIDEStructural = Set<String>()
        for path in pendingCreated {
            if Self.isIDEConfigPath(path) {
                eventBus.publish(IDEFileCreatedEvent(url: URL(fileURLWithPath: path)))
            } else {
                eventBus.publish(FileCreatedEvent(url: URL(fileURLWithPath: path)))
                nonIDEStructural.insert(path)
                if let mod = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    lastKnownModDates[path] = mod
                }
            }
        }
        for path in actualModifications {
            eventBus.publish(FileModifiedEvent(url: URL(fileURLWithPath: path)))
        }
        for path in pendingDeleted {
            if Self.isIDEConfigPath(path) {
                eventBus.publish(IDEFileDeletedEvent(url: URL(fileURLWithPath: path)))
            } else {
                eventBus.publish(FileDeletedEvent(url: URL(fileURLWithPath: path)))
                nonIDEStructural.insert(path)
                lastKnownModDates.removeValue(forKey: path)
            }
        }

        if !nonIDEStructural.isEmpty {
            eventBus.publish(FileTreeRefreshRequestedEvent(paths: Array(nonIDEStructural).sorted()))
        }
    }
}

final class ProjectRootFileWatcher: @unchecked Sendable {
    private let actor: ProjectRootFileWatcherActor

    init(
        rootURL: URL,
        eventBus: EventBusProtocol,
        excludePatterns: [String]
    ) {
        self.actor = ProjectRootFileWatcherActor(
            rootURL: rootURL,
            eventBus: eventBus,
            excludePatterns: excludePatterns
        )
    }

    func start() {
        Task { await actor.start() }
    }

    func stop() {
        Task { await actor.stop() }
    }
}
