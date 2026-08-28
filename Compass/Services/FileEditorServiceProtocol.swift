import Foundation

@MainActor
protocol FileEditorServiceProtocol: AnyObject, StatePublisherProtocol {
    var selectedFile: String? { get set }
    var editorContent: String { get set }
    var editorLanguage: String { get set }
    var isDirty: Bool { get }
    var canSave: Bool { get }
    var displayName: String { get }

    func loadFile(from url: URL)
    func saveFile()
    func saveFileAs(to url: URL)
    func newFile()
    func handleError(_ error: AppError)
}
