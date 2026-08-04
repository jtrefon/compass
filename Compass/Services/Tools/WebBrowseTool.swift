import Foundation

/// Session-based web browsing tool using WKWebView.
/// Supports multi-step navigation: open, read, click, go_back, go_forward, close.
/// Each session maintains its own browser state (cookies, history, JS context).
struct WebBrowseTool: AITool {
    let name = "web_fetch"
let description = "Browse a webpage and extract its main readable content."

    var parameters: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "description": "Action: open (default), read, click, links, go_back, go_forward, reload, close."
                ],
                "url": [
                    "type": "string",
                    "description": "URL to navigate to. Required for action=open."
                ],
                "session_id": [
                    "type": "string",
                    "description": "Existing session ID for multi-step navigation. Returned when you open a session."
                ],
                "selector": [
                    "type": "string",
                    "description": "CSS selector for action=click (e.g. 'a.nav-link', '#submit-btn')."
                ],
                "max_chars": [
                    "type": "integer",
                    "description": "Maximum characters to return (default 10000, max 50000)."
                ]
            ],
            "required": []
        ]
    }

    func execute(arguments: ToolArguments) async throws -> String {
        let raw = arguments.raw
        let action = (raw["action"] as? String)?.lowercased() ?? "open"
        let urlString = raw["url"] as? String
        let sessionID = raw["session_id"] as? String
        let selector = raw["selector"] as? String
        let maxChars = min(50000, max(1000, raw["max_chars"] as? Int ?? 10000))

        if action == "open" {
            guard let urlString, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Error: 'url' is required for action=open."
            }
            guard let url = URL(string: urlString) else {
                return "Error: Invalid URL: \(urlString)"
            }

            if let sessionID {
                return try await openInExisting(sessionID: sessionID, url: url, maxChars: maxChars)
            } else {
                return try await openNew(url: url, maxChars: maxChars)
            }
        }

        guard let sessionID else {
            return "Error: 'session_id' is required for action=\(action). Use action=open first to get a session."
        }

        return try await performAction(sessionID: sessionID, action: action, selector: selector, maxChars: maxChars)
    }

    @MainActor
    private func openNew(url: URL, maxChars: Int) async throws -> String {
        let sessionID = await WebSessionStore.shared.createSession(persistent: true)
        guard let session = await WebSessionStore.shared.get(sessionID) else {
            return "Error: Failed to create browsing session."
        }
        let text = (try? await session.navigate(to: url, timeout: 25)) ?? "(navigation failed)"
        return trimAndFormat(text: text, maxChars: maxChars, sessionID: sessionID)
    }

    @MainActor
    private func openInExisting(sessionID: String, url: URL, maxChars: Int) async throws -> String {
        guard let session = await WebSessionStore.shared.get(sessionID) else {
            return "Error: Session '\(sessionID)' not found. Use action=open without session_id to create one."
        }
        let text = (try? await session.navigate(to: url, timeout: 25)) ?? "(navigation failed)"
        return trimAndFormat(text: text, maxChars: maxChars, sessionID: sessionID)
    }

    @MainActor
    private func performAction(sessionID: String, action: String, selector: String?, maxChars: Int) async throws -> String {
        guard let session = await WebSessionStore.shared.get(sessionID) else {
            return "Error: Session '\(sessionID)' not found. Use action=open without session_id to create one."
        }

        let text: String
        switch action {
        case "read":
            text = (try? await session.getText()) ?? "(read failed)"
        case "click":
            guard let selector else { return "Error: 'selector' is required for action=click." }
            text = (try? await session.click(selector: selector, timeout: 25)) ?? "(click failed)"
        case "links":
            text = (try? await session.getLinks()) ?? "(get links failed)"
        case "go_back":
            text = (try? await session.goBack()) ?? "(go back failed)"
        case "go_forward":
            text = (try? await session.goForward()) ?? "(go forward failed)"
        case "reload":
            text = (try? await session.reload()) ?? "(reload failed)"
        case "close":
            await WebSessionStore.shared.close(sessionID)
            return "Session \(sessionID) closed."
        default:
            text = "Error: Unknown action '\(action)'. Valid actions: open, read, click, links, go_back, go_forward, reload, close."
        }

        return trimAndFormat(text: text, maxChars: maxChars, sessionID: sessionID)
    }

    private func trimAndFormat(text: String, maxChars: Int, sessionID: String) -> String {
        guard text != "(empty page)" && text != "" else {
            return "Session: \(sessionID) | 0 chars\n\n(empty page)"
        }
        let trimmed = text.count > maxChars
            ? String(text.prefix(maxChars)) + "\n\n... [truncated, use max_chars parameter for more]"
            : text
        return "Session: \(sessionID) | \(text.count) chars\n\n\(trimmed)"
    }
}
