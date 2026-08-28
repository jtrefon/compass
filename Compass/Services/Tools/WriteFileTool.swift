//
//  WriteFileTool.swift
//  Compass
//
//  Created by AI Assistant on 11/01/2026.
//

import Foundation

/// Write content to a file at the specified path. Overwrites if it exists.
struct WriteFileTool: AITool {
    let name = "write"
    let description = "Create a NEW file or fully rewrite an existing file. For targeted changes to an existing file, use the `edit` tool with old_string/new_string instead — safer (refuses unknown/ambiguous matches) and does NOT require a prior `read`."
    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Project-root-relative path (e.g. \"src/App.jsx\"). The tool resolves relative paths to the correct absolute location."
                ],
                "content": [
                    "type": "string",
                    "description": "The content to write to the file."
                ],
                "mode": [
                    "type": "string",
                    "description": "One of: apply, propose. Default: apply.",
                    "enum": ["apply", "propose"]
                ],
                "patch_set_id": [
                    "type": "string",
                    "description": "Patch set identifier to stage into when mode=propose."
                ]
            ],
            "required": ["path", "content"]
        ]
    }

    let fileSystemService: FileSystemService
    let pathValidator: PathValidator
    let eventBus: EventBusProtocol

    func execute(arguments: ToolArguments) async throws -> String {
        let arguments = arguments.raw
        guard let path = arguments["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let keys = arguments.keys.sorted().joined(separator: ", ")
            throw AppError.aiServiceError(
                "Missing 'path' argument for write_file. Provided keys: [\(keys)]. "
                    + "Fix: include a non-empty path (absolute or project-root-relative). Example:\n"
                    + "{\n  \"path\": \"src/App.css\",\n  \"content\": \"/* ... */\"\n}"
            )
        }
        guard let content = arguments["content"] as? String else {
            let keys = arguments.keys.sorted().joined(separator: ", ")
            throw AppError.aiServiceError(
                "Missing 'content' argument for write_file. Provided keys: [\(keys)]. "
                    + "Fix: include a 'content' string with the file body."
            )
        }

        let context = ToolInvocationContext.from(arguments: arguments)
        let mode = context.mode
        let toolCallId = context.toolCallId
        let patchSetId = context.patchSetId

        let url = try pathValidator.validateAndResolve(path)
        let relativePath = pathValidator.relativePath(for: url)

        if mode == "propose" {
            try await FileToolProposalStager.stageWrite(
                patchSetId: patchSetId,
                toolCallId: toolCallId,
                relativePath: relativePath,
                content: content
            )
            await AIToolTraceLogger.shared.log(type: "fs.write_file_proposed", data: [
                "path": relativePath,
                "bytes": content.utf8.count,
                "patchSetId": patchSetId
            ])
            return FileToolProposalStager.proposedWriteMessage(
                relativePath: relativePath,
                patchSetId: patchSetId
            )
        }

        if FileManager.default.fileExists(atPath: url.path),
           let existingContent = try? fileSystemService.readFile(at: url),
           existingContent == content {
            return "No-op: content already matches for \(relativePath)"
        }

        try await FileToolWriteApplier.applyWrite(
            FileToolWriteApplier.ApplyWriteRequest(
                fileSystemService: fileSystemService,
                eventBus: eventBus,
                url: url,
                relativePath: relativePath,
                content: content,
                traceType: "fs.write_file",
                conversationId: context.conversationId
            )
        )
        return "Successfully wrote to \(relativePath)"
    }
}
