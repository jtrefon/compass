import Foundation

/// Per-project session registry metadata: one file (`.ide/chat/sessions/manifest.json`)
/// that makes app startup fast and crash-safe. It mirrors what the heavy
/// snapshot files contain without decoding them — boot reads the manifest,
/// snapshots are decoded lazily on demand.
///
/// The manifest is the SINGLE source of truth for:
/// - which sessions exist (with subject / dates / size / message count)
/// - which are open tabs (`order`)
/// - which are archived (closed) (`archivedIds`)
/// - which tab is active (`selectedId`)
public struct SessionManifest: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var subject: String
        public var mode: AIMode
        public var createdAt: Date
        public var updatedAt: Date
        public var closedAt: Date?
        public var messageCount: Int
        public var byteSize: Int

        public init(
            subject: String,
            mode: AIMode,
            createdAt: Date,
            updatedAt: Date,
            closedAt: Date?,
            messageCount: Int,
            byteSize: Int
        ) {
            self.subject = subject
            self.mode = mode
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.closedAt = closedAt
            self.messageCount = messageCount
            self.byteSize = byteSize
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
            mode = try c.decodeIfPresent(AIMode.self, forKey: .mode) ?? .chat
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
            closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
            messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
            byteSize = try c.decodeIfPresent(Int.self, forKey: .byteSize) ?? 0
        }
    }

    public var version: Int
    public var selectedId: String?
    public var order: [String]
    public var archivedIds: [String]
    public var sessions: [String: Entry]

    public init(
        version: Int = 1,
        selectedId: String? = nil,
        order: [String] = [],
        archivedIds: [String] = [],
        sessions: [String: Entry] = [:]
    ) {
        self.version = version
        self.selectedId = selectedId
        self.order = order
        self.archivedIds = archivedIds
        self.sessions = sessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        selectedId = try c.decodeIfPresent(String.self, forKey: .selectedId)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        archivedIds = try c.decodeIfPresent([String].self, forKey: .archivedIds) ?? []
        sessions = try c.decodeIfPresent([String: Entry].self, forKey: .sessions) ?? [:]
    }

    /// Session ids that are open tabs (order) or archived — i.e. everything
    /// the app knows about, in no particular order.
    var allIds: Set<String> {
        Set(order).union(archivedIds)
    }

    /// True when the manifest is empty and there is no active selection.
    var isEmpty: Bool {
        sessions.isEmpty && order.isEmpty && archivedIds.isEmpty && selectedId == nil
    }
}

/// Loads/saves the session manifest and can rebuild it from the on-disk
/// snapshot store when the manifest is missing, corrupt, or orphaned
/// (registry regression recovery).
final class SessionManifestStore {

    static let manifestFileName = "manifest.json"

    // MARK: - Paths

    static func sessionsDirectory(projectRoot: URL) -> URL {
        projectRoot
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func snapshotURL(sessionId: String, projectRoot: URL) -> URL {
        sessionsDirectory(projectRoot: projectRoot)
            .appendingPathComponent("\(sessionId).json")
    }

    static func manifestURL(projectRoot: URL) -> URL {
        sessionsDirectory(projectRoot: projectRoot)
            .appendingPathComponent(manifestFileName)
    }

    /// True when the session id has a snapshot file on disk (used to validate
    /// registry entries without decoding).
    static func snapshotExists(sessionId: String, projectRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL(sessionId: sessionId, projectRoot: projectRoot).path)
    }

    static func fileSize(of url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? Int) ?? (attrs[.size] as? UInt64).map { Int($0) } ?? 0
    }

    // MARK: - Load / save

    func load(projectRoot: URL) -> SessionManifest? {
        let url = Self.manifestURL(projectRoot: projectRoot)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(SessionManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    func save(_ manifest: SessionManifest, projectRoot: URL) {
        let dir = Self.sessionsDirectory(projectRoot: projectRoot)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = Self.manifestURL(projectRoot: projectRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func deleteSnapshot(sessionId: String, projectRoot: URL) {
        try? FileManager.default.removeItem(at: Self.snapshotURL(sessionId: sessionId, projectRoot: projectRoot))
    }

    // MARK: - Rebuild from disk (heal path)

    /// Scans the on-disk snapshot store and rebuilds a manifest from it.
    /// Used when the manifest is missing/corrupt or the registry references
    /// sessions that no longer exist (self-heal: nothing on disk is ever
    /// forgotten just because the registry broke).
    func rebuildFromDisk(projectRoot: URL) -> SessionManifest {
        var manifest = SessionManifest()
        let dir = Self.sessionsDirectory(projectRoot: projectRoot)
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return manifest
        }

        for url in urls {
            let name = url.lastPathComponent
            // Only `<uuid>.json` files are session snapshots; manifest + rotated
            // backups (`.bak-*`) are ignored.
            guard name.hasSuffix(".json"),
                  !name.hasPrefix(Self.manifestFileName),
                  !name.contains(".bak-"),
                  name.count == 41 else { continue }
            let sessionId = String(name.dropLast(5))
            guard let snapshot = SessionManager.SessionSnapshot.loadFromDisk(sessionId: sessionId, projectRoot: projectRoot) else { continue }
            manifest.sessions[sessionId] = SessionManifest.Entry(
                subject: snapshot.subject,
                mode: snapshot.mode,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                closedAt: snapshot.closedAt,
                messageCount: snapshot.messages.count,
                byteSize: Self.fileSize(of: url)
            )
        }
        return manifest
    }
}
