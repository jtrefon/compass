#if DEBUG
import Foundation
import UniformTypeIdentifiers

class MockFileDialogService: FileDialogServiceProtocol {
    func openFileOrFolder() async -> URL? { nil }
    func openFolder() async -> URL? { nil }
    func saveFile(defaultFileName _: String, allowedContentTypes: [UTType]) async -> URL? { nil }

    func promptForNewProjectFolder(defaultName: String) async -> URL? {
        URL(fileURLWithPath: "/Users/test/Desktop").appendingPathComponent(defaultName)
    }
}
#endif
