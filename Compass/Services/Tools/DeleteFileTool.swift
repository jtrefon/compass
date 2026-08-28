import Foundation

/// Delete a file
struct DeleteFileTool: AITool {
    let name = "rm"
    let description = "Delete a file at the specified path."
    var parameters: [String: Any] {
        FileToolParameterSchemaBuilder.objectSchema(
            properties: [
                "path": FileToolParameterSchemaBuilder.pathProperty(
                    description: "The absolute path to the file to delete."
                ),
                "mode": FileToolParameterSchemaBuilder.modeProperty(),
                "patch_set_id": FileToolParameterSchemaBuilder.patchSetIdProperty()
            ],
            required: ["path"]
        )
    }
    let pathValidator: PathValidator
    let eventBus: EventBusProtocol

    func execute(arguments: ToolArguments) async throws -> String {
        let arguments = arguments.raw
        guard let path = arguments["path"] as? String else {
            throw AppError.aiServiceError("Missing 'path' argument for delete_file")
        }

        let context = ToolInvocationContext.from(arguments: arguments)
        let mode = context.mode
        let toolCallId = context.toolCallId
        let patchSetId = context.patchSetId

        let url = try pathValidator.validateAndResolve(path)

        if mode == "propose" {
            let rel = pathValidator.relativePath(for: url)
            try await FileToolProposalStager.stageDelete(
                patchSetId: patchSetId,
                toolCallId: toolCallId,
                relativePath: rel
            )
            return FileToolProposalStager.proposedDeleteFileMessage(relativePath: rel, patchSetId: patchSetId)
        }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            throw AppError.aiServiceError(
                "delete_file failed: file does not exist at \(pathValidator.relativePath(for: url))"
            )
        }
        try fileManager.removeItem(at: url)
        Task { @MainActor in
            eventBus.publish(FileDeletedEvent(url: url))
        }
        return "Successfully deleted file at \(pathValidator.relativePath(for: url))"
    }
}
