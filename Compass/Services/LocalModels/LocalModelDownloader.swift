import Foundation

final class DownloadTaskDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let continuation: CheckedContinuation<Void, Error>
    private let destinationURL: URL
    private let lock = NSLock()
    private var hasResumed = false

    init(destinationURL: URL, continuation: CheckedContinuation<Void, Error>, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destinationURL = destinationURL
        self.continuation = continuation
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let httpResponse = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw LocalModelDownloader.DownloadError.httpError(status: httpResponse.statusCode)
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            resumeOnce(.success(()))
        } catch {
            resumeOnce(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            resumeOnce(.failure(error))
        }
    }

    /// A `CheckedContinuation` traps if resumed twice; `didFinishDownloadingTo`
    /// and `didCompleteWithError` can both fire for the same task (e.g. when the
    /// file move fails), so resume exactly once.
    private func resumeOnce(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

actor LocalModelDownloader {
    struct Progress: Sendable {
        let completedArtifacts: Int
        let totalArtifacts: Int
        let currentFileName: String?
        let currentFileBytesDownloaded: Int64
        let currentFileBytesTotal: Int64?

        var fractionCompleted: Double {
            guard totalArtifacts > 0 else { return 0 }
            let baseFraction = Double(completedArtifacts) / Double(totalArtifacts)
            
            var currentFileFraction: Double = 0
            if let total = currentFileBytesTotal, total > 0 {
                // Limit to 0...1 to be safe
                let boundedDownloaded = min(currentFileBytesDownloaded, total)
                currentFileFraction = Double(boundedDownloaded) / Double(total)
            }
            
            return baseFraction + (currentFileFraction / Double(totalArtifacts))
        }
    }

    enum DownloadError: LocalizedError {
        case invalidResponse
        case httpError(status: Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid download response."
            case .httpError(let status):
                return "Download failed with status code \(status)."
            }
        }
    }

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func download(
        model: LocalModelDefinition,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let modelDirectory = try LocalModelFileStore.ensureCanonicalInstallation(for: model)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        var completed = 0
        onProgress(Progress(completedArtifacts: completed, totalArtifacts: model.artifacts.count, currentFileName: nil, currentFileBytesDownloaded: 0, currentFileBytesTotal: nil))

        for artifact in model.artifacts {
            let destinationURL = try LocalModelFileStore.artifactURL(modelId: model.id, fileName: artifact.fileName)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                completed += 1
                onProgress(Progress(completedArtifacts: completed, totalArtifacts: model.artifacts.count, currentFileName: artifact.fileName, currentFileBytesDownloaded: 0, currentFileBytesTotal: nil))
                continue
            }

            onProgress(Progress(completedArtifacts: completed, totalArtifacts: model.artifacts.count, currentFileName: artifact.fileName, currentFileBytesDownloaded: 0, currentFileBytesTotal: nil))

            let totalCount = model.artifacts.count
            let capturedCompleted = completed
            let artifactFileName = artifact.fileName
            
            try await withCheckedThrowingContinuation { continuation in
                let delegate = DownloadTaskDelegate(destinationURL: destinationURL, continuation: continuation) { downloaded, total in
                    onProgress(Progress(
                        completedArtifacts: capturedCompleted,
                        totalArtifacts: totalCount,
                        currentFileName: artifactFileName,
                        currentFileBytesDownloaded: downloaded,
                        currentFileBytesTotal: total
                    ))
                }
                
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: artifact.url)
                task.resume()
            }

            completed += 1
            onProgress(Progress(completedArtifacts: completed, totalArtifacts: model.artifacts.count, currentFileName: artifact.fileName, currentFileBytesDownloaded: 0, currentFileBytesTotal: nil))
        }
    }
}
