import Foundation

/// Manages persistent web browsing sessions on the main actor.
/// Each session wraps a WebKitSession (WKWebView) for full JS execution.
/// Sessions are keyed by UUID strings and can be created as persistent
/// (cookies/storage survive) or non-persistent (clean slate).
@MainActor
final class WebSessionStore {
    static let shared = WebSessionStore()
    private var sessions: [String: WebKitSession] = [:]

    private init() {}

    func createSession(persistent: Bool = false, sessionId: String = UUID().uuidString) -> String {
        sessions[sessionId] = nil
        let session = WebKitSession(persistentData: persistent)
        sessions[sessionId] = session
        return sessionId
    }

    func get(_ id: String) -> WebKitSession? {
        sessions[id]
    }

    func close(_ id: String) {
        sessions[id]?.close()
        sessions.removeValue(forKey: id)
    }

    func closeAll() {
        for (_, session) in sessions {
            session.close()
        }
        sessions.removeAll()
    }

    func activeCount() -> Int {
        sessions.count
    }
}
