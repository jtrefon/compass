import Foundation

@MainActor
protocol WorkspaceServiceProtocol: AnyObject, StatePublisherProtocol {
    var currentDirectory: URL? { get set }
    func createFile(named name: String, in directory: URL) async
    func createFolder(named name: String, in directory: URL) async
    func deleteItem(at url: URL) async
    func renameItem(at url: URL, to newName: String) async -> URL?
    func navigateToParent()
    func navigateTo(subdirectory: String)
    func isValidPath(_ path: String) -> Bool
    func makePathValidator(projectRoot: URL) -> PathValidator
    func makePathValidatorForCurrentDirectory() -> PathValidator?
    func handleError(_ error: AppError)
}
