import Foundation

@MainActor
enum TestSupport {
    static var testFiles: [URL] = []

    static func cleanupTestFiles() {
        for file in testFiles {
            try? FileManager.default.removeItem(at: file)
        }
        testFiles.removeAll()
    }
}
