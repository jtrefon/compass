import Foundation

@MainActor
enum DiagnosticURLResolver {
    static func resolve(_ diagnostic: Diagnostic, context: IDEContext) -> URL? {
        if diagnostic.relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: diagnostic.relativePath)
        }

        guard let root = context.workspace.currentDirectory?.standardizedFileURL else {
            context.lastError = "No workspace open."
            return nil
        }

        do {
            return try context.workspaceService
                .makePathValidator(projectRoot: root)
                .validateAndResolve(diagnostic.relativePath)
        } catch {
            context.lastError = error.localizedDescription
            return nil
        }
    }
}
