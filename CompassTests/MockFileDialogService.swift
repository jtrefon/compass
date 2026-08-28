#if DEBUG
import Foundation
import UniformTypeIdentifiers
@testable import Compass

class MockFileDialogService: FileDialogServiceProtocol {
    func openFileOrFolder() async -> URL? { nil }
    func openFolder() async -> URL? { nil }
    func saveFile(defaultFileName _: String, allowedContentTypes: [UTType]) async -> URL? { nil }

    func promptForNewProjectFolder(defaultName: String) async -> URL? {
        URL(fileURLWithPath: "/Users/test/Desktop").appendingPathComponent(defaultName)
    }
}
#endif
