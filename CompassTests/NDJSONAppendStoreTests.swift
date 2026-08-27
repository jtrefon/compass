import XCTest
@testable import Compass

final class NDJSONAppendStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndjson-append-store-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func readLines(_ fileURL: URL) -> [[String: Any]] {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { chunk in
            try? JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [String: Any]
        }
    }

    func testAppendCreatesMissingDirectoriesAndFile() async {
        let store = NDJSONAppendStore()
        let fileURL = tempDir.appendingPathComponent("a/b/c/log.ndjson")

        await store.append(Data("{\"n\":1}\n".utf8), to: fileURL)

        let data = FileManager.default.contents(atPath: fileURL.path)
        XCTAssertNotNil(data)
        XCTAssertEqual(String(data: data!, encoding: .utf8), "{\"n\":1}\n")
        let failures = await store.writeFailures
        XCTAssertEqual(failures, 0)
    }

    func testConcurrentAppendsPreserveEveryLineWithoutInterleaving() async {
        let store = NDJSONAppendStore()
        let fileURL = tempDir.appendingPathComponent("concurrent.ndjson")
        let writers = 40
        let linesPerWriter = 25

        await withTaskGroup(of: Void.self) { group in
            for w in 0..<writers {
                group.addTask {
                    for i in 0..<linesPerWriter {
                        // Long-ish payload makes interleaved partial writes visible.
                        let payload = String(repeating: "x", count: 400)
                        await store.append(Data("{\"writer\":\(w),\"i\":\(i),\"payload\":\"\(payload)\"}\n".utf8), to: fileURL)
                    }
                }
            }
        }
        await store.closeAll()

        let parsed = readLines(fileURL)
        XCTAssertEqual(parsed.count, writers * linesPerWriter, "every appended line must survive")
        for entry in parsed {
            XCTAssertNotNil(entry["payload"], "no torn/interleaved lines allowed")
            XCTAssertEqual(entry.keys.count, 3)
        }
        let failures = await store.writeFailures
        XCTAssertEqual(failures, 0)
    }

    func testOrderingIsEmissionOrderForSequentialProducers() async {
        let store = NDJSONAppendStore()
        let fileURL = tempDir.appendingPathComponent("ordered.ndjson")

        for i in 0..<100 {
            await store.append(Data("{\"seq\":\(i)}\n".utf8), to: fileURL)
        }
        await store.closeAll()

        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let text = String(data: data, encoding: .utf8) else {
            return XCTFail("log file missing")
        }
        let seqs = text.split(separator: "\n").compactMap { chunk -> Int? in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [String: Any],
                  let seq = obj["seq"] as? Int else { return nil }
            return seq
        }
        XCTAssertEqual(seqs, Array(0..<100))
    }

    func testFailureIsCountedWhenTargetIsUnwritable() async {
        let store = NDJSONAppendStore()
        // A regular FILE where a directory component must be created —
        // directory creation fails on every attempt.
        let blocker = tempDir.appendingPathComponent("blocker")
        XCTAssertNoThrow(try Data("not a dir".utf8).write(to: blocker, options: .atomic))
        let fileURL = blocker.appendingPathComponent("nested/log.ndjson")

        await store.append(Data("{}\n".utf8), to: fileURL)

        let failures = await store.writeFailures
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
}
