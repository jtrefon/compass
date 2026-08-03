import Foundation

enum FileToolProposalStager {
    struct StageWriteAndMessageRequest {
        let patchSetId: String
        let toolCallId: String
        let relativePath: String
        let content: String
        let messageBuilder: (String, String) -> String
    }

    static func stageWrite(
        patchSetId: String,
        toolCallId: String,
        relativePath: String,
        content: String
    ) async throws {
        try await PatchSetStore.shared.stageWrite(
            patchSetId: patchSetId,
            toolCallId: toolCallId,
            relativePath: relativePath,
            content: content
        )
    }

    static func stageDelete(
        patchSetId: String,
        toolCallId: String,
        relativePath: String
    ) async throws {
        try await PatchSetStore.shared.stageDelete(
            patchSetId: patchSetId,
            toolCallId: toolCallId,
            relativePath: relativePath
        )
    }

    static func proposedCreateFileMessage(relativePath: String, patchSetId: String) -> String {
        "Proposed create file at \(relativePath) (patch_set_id=\(patchSetId))."
    }

    static func proposedDeleteFileMessage(relativePath: String, patchSetId: String) -> String {
        "Proposed delete \(relativePath) (patch_set_id=\(patchSetId))."
    }

    static func proposedReplaceMessage(relativePath: String, patchSetId: String) -> String {
        "Proposed replace in \(relativePath) (patch_set_id=\(patchSetId))."
    }

    static func proposedWriteMessage(relativePath: String, patchSetId: String) -> String {
        "Proposed write to \(relativePath) (patch_set_id=\(patchSetId))."
    }

    static func stageWriteAndProposedMessage(_ request: StageWriteAndMessageRequest) async throws -> String {
        try await stageWrite(
            patchSetId: request.patchSetId,
            toolCallId: request.toolCallId,
            relativePath: request.relativePath,
            content: request.content
        )
        return request.messageBuilder(request.relativePath, request.patchSetId)
    }

    static func stageDeleteAndProposedMessage(
        patchSetId: String,
        toolCallId: String,
        relativePath: String
    ) async throws -> String {
        try await stageDelete(
            patchSetId: patchSetId,
            toolCallId: toolCallId,
            relativePath: relativePath
        )
        return proposedDeleteFileMessage(relativePath: relativePath, patchSetId: patchSetId)
    }
}
