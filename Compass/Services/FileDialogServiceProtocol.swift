import Foundation
import UniformTypeIdentifiers

@MainActor
protocol FileDialogServiceProtocol {
    func openFileOrFolder() async -> URL?
    func openFolder() async -> URL?
    func saveFile(defaultFileName: String, allowedContentTypes: [UTType]) async -> URL?
    func promptForNewProjectFolder(defaultName: String) async -> URL?
}
