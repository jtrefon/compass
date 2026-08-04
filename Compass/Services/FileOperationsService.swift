import Foundation

private actor FileIOActor {
    private let fileSystemService: FileSystemService
    private let eventBus: EventBusProtocol

    init(fileSystemService: FileSystemService, eventBus: EventBusProtocol) {
        self.fileSystemService = fileSystemService
        self.eventBus = eventBus
    }

    func writeFile(content: String, to url: URL) throws {
        let standardized = url.standardizedFileURL
        let existed = FileManager.default.fileExists(atPath: standardized.path)

        try fileSystemService.writeFile(content: content, to: standardized)

        if existed {
            eventBus.publish(FileModifiedEvent(url: standardized))
        } else {
            eventBus.publish(FileCreatedEvent(url: standardized))
        }
    }

    func createFile(named trimmedName: String, in directory: URL) throws -> URL {
        let newFileURL = directory.standardizedFileURL
            .appendingPathComponent(trimmedName)
            .standardizedFileURL

        if FileManager.default.fileExists(atPath: newFileURL.path) {
            throw AppError.invalidFilePath("File already exists: \(trimmedName)")
        }

        try fileSystemService.writeFile(content: "", to: newFileURL)
        eventBus.publish(FileCreatedEvent(url: newFileURL))
        return newFileURL
    }

    func createFolder(named trimmedName: String, in directory: URL) throws {
        let newFolderURL = directory.standardizedFileURL
            .appendingPathComponent(trimmedName)
            .standardizedFileURL

        if FileManager.default.fileExists(atPath: newFolderURL.path) {
            throw AppError.invalidFilePath("Folder already exists: \(trimmedName)")
        }

        try FileManager.default.createDirectory(at: newFolderURL, withIntermediateDirectories: false, attributes: nil)
    }

    func deleteItem(at url: URL) async throws {
        let standardized = url.standardizedFileURL
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: standardized.path) {
            throw AppError.fileNotFound(standardized.path)
        }

        let isDirectory = (try? standardized.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            let enumerator = fileManager.enumerator(
                at: standardized,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: nil
            )
            while let next = enumerator?.nextObject() as? URL {
                eventBus.publish(FileDeletedEvent(url: next.standardizedFileURL))
            }
        }

        do {
            try fileManager.trashItem(at: standardized, resultingItemURL: nil)
        } catch {
            await CrashReporter.shared.capture(
                error,
                context: CrashReportContext(operation: "FileIOActor.deleteItem"),
                metadata: ["path": standardized.path],
                file: #fileID,
                function: #function,
                line: #line
            )
            try fileManager.removeItem(at: standardized)
        }

        eventBus.publish(FileDeletedEvent(url: standardized))
    }

    func renameItem(at url: URL, to trimmedName: String) throws -> URL {
        let standardized = url.standardizedFileURL
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: standardized.path) {
            throw AppError.fileNotFound(standardized.path)
        }

        let destination = standardized.deletingLastPathComponent().appendingPathComponent(trimmedName)
        if fileManager.fileExists(atPath: destination.path) {
            throw AppError.invalidFilePath("File already exists: \(trimmedName)")
        }

        try fileManager.moveItem(at: standardized, to: destination)
        let standardizedDestination = destination.standardizedFileURL
        eventBus.publish(FileRenamedEvent(oldUrl: standardized, newUrl: standardizedDestination))
        return standardizedDestination
    }
}

@MainActor
final class FileOperationsService {
    private let ioActor: FileIOActor

    init(fileSystemService: FileSystemService, eventBus: EventBusProtocol) {
        self.ioActor = FileIOActor(fileSystemService: fileSystemService, eventBus: eventBus)
    }

    private func validateFileName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw AppError.invalidFilePath("Name is empty")
        }
        if trimmed.contains("/") || trimmed.contains("..") {
            throw AppError.invalidFilePath("Invalid name: \(trimmed)")
        }
        return trimmed
    }

    func writeFile(content: String, to url: URL) async throws {
        try await ioActor.writeFile(content: content, to: url)
    }

    func createFile(named name: String, in directory: URL) async throws -> URL {
        let trimmedName = try validateFileName(name)
        return try await ioActor.createFile(named: trimmedName, in: directory)
    }

    func createFolder(named name: String, in directory: URL) async throws {
        let trimmedName = try validateFileName(name)
        try await ioActor.createFolder(named: trimmedName, in: directory)
    }

    func deleteItem(at url: URL) async throws {
        try await ioActor.deleteItem(at: url)
    }

    func renameItem(at url: URL, to newName: String) async throws -> URL {
        let trimmedName = try validateFileName(newName)
        return try await ioActor.renameItem(at: url, to: trimmedName)
    }
}
