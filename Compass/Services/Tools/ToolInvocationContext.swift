import Foundation

struct ToolInvocationContext {
    let mode: String
    let toolCallId: String
    let patchSetId: String
    let conversationId: String?

    static func from(arguments: [String: Any]) -> ToolInvocationContext {
        let mode = (arguments["mode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "apply"
        let toolCallId = (arguments["_tool_call_id"] as? String) ?? UUID().uuidString
        let conversationId = (arguments["_conversation_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let patchSetId = (arguments["patch_set_id"] as? String)
            ?? conversationId
            ?? "default"

        return ToolInvocationContext(
            mode: mode,
            toolCallId: toolCallId,
            patchSetId: patchSetId,
            conversationId: conversationId?.isEmpty == false ? conversationId : nil
        )
    }
}
