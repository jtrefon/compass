import Foundation

public actor PatchSetStore {
    public static let shared = PatchSetStore()

    private var projectRoot: URL?

    public func setProjectRoot(_ root: URL) {
        self.projectRoot = root
    }

    public func stagingRootDirectory() -> URL? {
        projectRoot?
            .appendingPathComponent(AppConstantsFileSystem.projectDirName, isDirectory: true)
            .appendingPathComponent("staging", isDirectory: true)
    }

    public func patchSetDirectory(patchSetId: String) -> URL? {
        stagingRootDirectory()?.appendingPathComponent(
            patchSetId,
            isDirectory: true
        )
    }

    private func manifestURL(patchSetId: String) -> URL? {
        patchSetDirectory(patchSetId: patchSetId)?.appendingPathComponent(
            "manifest.json"
        )
    }

    private func blobsDirectory(patchSetId: String) -> URL? {
        patchSetDirectory(patchSetId: patchSetId)?.appendingPathComponent(
            "blobs",
            isDirectory: true
        )
    }

    public func listPatchSetIds() -> [String] {
        guard let root = stagingRootDirectory() else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted()
    }

    public func loadManifest(patchSetId: String) -> PatchSetManifest? {
        guard let url = manifestURL(patchSetId: patchSetId) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PatchSetManifest.self, from: data)
    }

    public func upsertManifest(_ manifest: PatchSetManifest) throws {
        guard let dir = patchSetDirectory(patchSetId: manifest.id),
              let url = manifestURL(patchSetId: manifest.id) else {
            return
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    public func stageWrite(patchSetId: String, toolCallId: String, relativePath: String, content: String) throws {
        guard let blobsDir = blobsDirectory(patchSetId: patchSetId) else { return }
        try FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let blobName = UUID().uuidString + ".txt"
        let blobURL = blobsDir.appendingPathComponent(blobName)
        try content.data(using: .utf8)?.write(to: blobURL, options: [.atomic])

        var manifest = loadManifest(patchSetId: patchSetId)
            ?? PatchSetManifest(id: patchSetId, createdAt: Date(), entries: [])
        let entry = PatchSetEntry(
            toolCallId: toolCallId,
            kind: .write,
            relativePath: relativePath,
            stagedRelativeBlobPath: "blobs/\(blobName)"
        )
        manifest.entries.append(entry)
        try upsertManifest(manifest)
    }

    public func stageDelete(patchSetId: String, toolCallId: String, relativePath: String) throws {
        var manifest = loadManifest(patchSetId: patchSetId)
            ?? PatchSetManifest(id: patchSetId, createdAt: Date(), entries: [])
        let entry = PatchSetEntry(
            toolCallId: toolCallId,
            kind: .delete,
            relativePath: relativePath,
            stagedRelativeBlobPath: nil
        )
        manifest.entries.append(entry)
        try upsertManifest(manifest)
    }

    private func applyWriteEntry(_ entry: PatchSetEntry, root: URL, stagingDir: URL) throws {
        guard let blobRel = entry.stagedRelativeBlobPath else { return }
        let blobURL = stagingDir.appendingPathComponent(blobRel)
        let data = try Data(contentsOf: blobURL)
        let targetURL = root.appendingPathComponent(entry.relativePath)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: targetURL, options: [.atomic])
    }

    private func applyDeleteEntry(_ entry: PatchSetEntry, root: URL) throws {
        let targetURL = root.appendingPathComponent(entry.relativePath)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
    }

    public func applyPatchSet(patchSetId: String) throws -> [String] {
        guard let root = projectRoot else {
            throw AppError.aiServiceError("PatchSetStore missing project root")
        }
        guard let dir = patchSetDirectory(patchSetId: patchSetId) else {
            throw AppError.aiServiceError("PatchSetStore missing staging directory")
        }
        guard let manifest = loadManifest(patchSetId: patchSetId) else {
            throw AppError.aiServiceError("Patch set not found: \(patchSetId)")
        }

        var touched: [String] = []
        touched.reserveCapacity(manifest.entries.count)

        for entry in manifest.entries {
            switch entry.kind {
            case .write, .create, .replace:
                try applyWriteEntry(entry, root: root, stagingDir: dir)
                touched.append(entry.relativePath)
            case .delete:
                try applyDeleteEntry(entry, root: root)
                touched.append(entry.relativePath)
            }
        }

        return touched
    }

    public func clearPatchSet(patchSetId: String) throws {
        guard let dir = patchSetDirectory(patchSetId: patchSetId) else { return }
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
