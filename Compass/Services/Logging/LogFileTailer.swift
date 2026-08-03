import Combine
import Foundation

public struct LogLine: Identifiable, Sendable {
    public let id: Int
    public let text: String
}

@MainActor
final class LogFileTailer: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    private var nextLineId: Int = 0

    private var timerCancellable: AnyCancellable?
    private var fileHandle: FileHandle?
    private var lastOffset: UInt64 = 0

    private var isRunning: Bool = false

    private var fileURL: URL
    private let maxLines: Int

    // Performance optimization: track if we are already reading
    private var isReading: Bool = false

    // Batching buffer to reduce UI updates
    private var batchBuffer: [LogLine] = []
    private var lastUpdateTimestamp: Date = .distantPast

    init(fileURL: URL, maxLines: Int = 2_000) {
        self.fileURL = fileURL
        self.maxLines = maxLines
    }

    deinit {
        // fileHandle will be closed by system when released
    }

    func start() {
        stop()

        isRunning = true

        // Load initial data in background
        Task.detached(priority: .userInitiated) { [weak self, fileURL, maxLines] in
            guard let self = self else { return }

            let (initialLines, offset) = await Self.loadInitialInBackground(
                fileURL: fileURL, maxLines: maxLines)

            await MainActor.run { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.lines = initialLines.map { text in
                    let line = LogLine(id: self.nextLineId, text: text)
                    self.nextLineId += 1
                    return line
                }
                self.lastOffset = offset
                self.setupTimer()
            }
        }
    }

    private func setupTimer() {
        timerCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.readIncremental()
                }
            }
    }

    func stop() {
        timerCancellable = nil
        try? fileHandle?.close()
        fileHandle = nil

        isRunning = false
    }

    func clear() {
        lines = []
    }

    func setFileURL(_ url: URL) {
        let wasRunning = isRunning
        stop()
        fileURL = url
        clear()
        lastOffset = 0
        if wasRunning {
            start()
        }
    }

    private static func loadInitialInBackground(fileURL: URL, maxLines: Int) async -> (
        [String], UInt64
    ) {
        guard let data = try? Data(contentsOf: fileURL) else {
            return ([], 0)
        }

        let offset = UInt64(data.count)

        // Decode and split in background to avoid blocking MainActor
        // If file is very large, only process the last portion
        let bufferSize = 1024 * 512  // 512KB should be plenty for 2000 lines
        let dataToProcess: Data
        if data.count > bufferSize {
            dataToProcess = data.advanced(by: data.count - bufferSize)
        } else {
            dataToProcess = data
        }

        let content = String(data: dataToProcess, encoding: .utf8) ?? ""
        let split = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let lines = Array(split.suffix(maxLines))

        return (lines, offset)
    }

    private func readIncremental() async {
        guard isRunning, !isReading else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        isReading = true
        defer { isReading = false }

        // Use detached task for file reading and decoding
        let currentOffset = lastOffset
        let url = fileURL

        let result = await Task.detached(priority: .utility) {
            () -> (newLines: [String], bytesRead: UInt64)? in
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                try handle.seek(toOffset: currentOffset)
                guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }

                let appended = String(data: data, encoding: .utf8) ?? ""
                let split = appended.split(separator: "\n", omittingEmptySubsequences: true).map(
                    String.init)
                return (split, UInt64(data.count))
            } catch {
                return nil
            }
        }.value

        guard let (newLines, bytesRead) = result, !newLines.isEmpty else { return }

        lastOffset += bytesRead

        // Add to batch buffer with stable IDs
        for text in newLines {
            batchBuffer.append(LogLine(id: nextLineId, text: text))
            nextLineId += 1
        }

        // Only flush to UI if enough time has passed (e.g. 500ms) or buffer is large
        let now = Date()
        if now.timeIntervalSince(lastUpdateTimestamp) >= 0.5 || batchBuffer.count > 100 {
            flushBuffer()
            lastUpdateTimestamp = now
        }
    }

    private func flushBuffer() {
        guard !batchBuffer.isEmpty else { return }

        var out = lines
        out.append(contentsOf: batchBuffer)
        batchBuffer.removeAll()

        if out.count > maxLines {
            out.removeFirst(out.count - maxLines)
        }
        lines = out
    }
}
