import Foundation

actor ToolFileAccessLedger {
    static let shared = ToolFileAccessLedger()

    private var readPathsByConversationId: [String: Set<String>] = [:]

    func recordRead(relativePath: String, conversationId: String?) {
        guard let normalizedConversationId = normalizedConversationId(conversationId),
              let normalizedPath = normalizedRelativePath(relativePath) else {
            return
        }
        readPathsByConversationId[normalizedConversationId, default: []].insert(normalizedPath)
    }

    func hasRead(relativePath: String, conversationId: String?) -> Bool {
        guard let normalizedConversationId = normalizedConversationId(conversationId),
              let normalizedPath = normalizedRelativePath(relativePath) else {
            return false
        }
        return readPathsByConversationId[normalizedConversationId]?.contains(normalizedPath) == true
    }

    func readPaths(conversationId: String?) -> [String] {
        guard let normalizedConversationId = normalizedConversationId(conversationId) else {
            return []
        }
        return readPathsByConversationId[normalizedConversationId]?.sorted() ?? []
    }

    func reset(conversationId: String?) {
        guard let normalizedConversationId = normalizedConversationId(conversationId) else {
            return
        }
        readPathsByConversationId.removeValue(forKey: normalizedConversationId)
    }

    private func normalizedConversationId(_ conversationId: String?) -> String? {
        guard let conversationId else { return nil }
        let trimmed = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedRelativePath(_ relativePath: String) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : NSString(string: trimmed).standardizingPath
    }
}
