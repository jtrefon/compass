import XCTest
@testable import Compass

/// Shared orchestration helpers for the harness target. Every suite uses the
/// same runtime construction, send+wait polling, and file/markup assertions so
/// behavior can't drift between scenarios (Rule: harness orchestrates, never
/// implements — all of this calls production code).
@MainActor
enum HarnessRuntime {
    struct Runtime {
        let container: DependencyContainer
        let manager: ConversationManager
        let projectRoot: URL
    }

    /// Migrates provider configuration (model, base URL, API keys) from the
    /// LEGACY `tdc.compass` defaults domain into the current standard
    /// defaults. The project rebrand renamed the app's bundle id to
    /// `tdc.compass`, which starts with an empty settings domain. The harness
    /// must exercise the user's REAL provider config, so when the current
    /// domain lacks a value, the legacy domain is consulted.
    ///
    /// NOTE: no Keychain access anywhere — the SecureValueStore keychain path
    /// was removed (macOS prompts for the keychain password on every launch /
    /// test from an ad-hoc-signed app, breaking CI).
    private static func bridgeProviderApiKeys(from settingsStore: SettingsStore) {
        let legacyDefaults = UserDefaults(suiteName: "tdc.compass")
        let legacyKeys = [
            "OpenRouterAPIKey",
            "OpenRouterModel", "OpenRouterModelDisplayName",
            "OpenRouterBaseURL", "OpenRouterSystemPrompt",
            "OpenRouterReasoningMode", "OpenRouterToolPromptMode",
            "OpenRouterReasoningEnabled", "AI.OfflineModeEnabled",
            "AlibabaApiKey", "DeepSeekAPIKey", "KiloCodeAPIKey",
            "OpenCodeGoApiKey", "OpenCodeGoSubscriptionApiKey",
            "CustomEndpointAPIKey"
        ]
        for key in legacyKeys {
            guard (settingsStore.string(forKey: key) ?? "").isEmpty,
                  let legacyValue = legacyDefaults?.string(forKey: key),
                  !legacyValue.isEmpty else { continue }
            settingsStore.set(legacyValue, forKey: key)
        }
        if let legacyOffline = legacyDefaults?.object(forKey: "AI.OfflineModeEnabled") {
            if settingsStore.string(forKey: "AI.OfflineModeEnabled") == nil {
                settingsStore.set((legacyOffline as? Bool) ?? false, forKey: "AI.OfflineModeEnabled")
            }
        }
    }

    /// Creates a real DependencyContainer (auto-detected launch context), wires
    /// a temp project root, and returns the runtime. Set `mode` after the call.
    static func makeRuntime() async throws -> Runtime {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let container = DependencyContainer(
            launchContext: AppLaunchContext.detect(),
            settingsDefaults: .standard
        )

        // API keys + provider config live in plaintext UserDefaults (the
        // Keychain path was removed — it prompted for a password on every
        // launch/test). The rebrand moved the app's defaults domain from
        // tdc.compass to tdc.compass; bridge the legacy domain so harness
        // runs exercise the USER's configured providers.
        bridgeProviderApiKeys(from: container.settingsStore)
        guard let manager = container.conversationManager as? ConversationManager else {
            throw NSError(domain: "HarnessRuntime", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ConversationManager not the expected type"])
        }

        container.workspaceService.currentDirectory = projectRoot
        container.projectCoordinator.configureProject(root: projectRoot)

        // Brief settling period for async init
        try await Task.sleep(nanoseconds: 500_000_000)

        return Runtime(container: container, manager: manager, projectRoot: projectRoot)
    }

    /// Sends a prompt the same way the UI does and polls until completion or
    /// the deadline elapses.
    @discardableResult
    static func sendAndWait(
        _ text: String,
        manager: ConversationManager,
        timeout: TimeInterval = 120
    ) async throws -> Bool {
        manager.currentInput = text
        manager.sendMessage()

        let deadline = Date().addingTimeInterval(timeout)
        while manager.isSending && Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if manager.isSending {
            print("[HARNESS] timed out after \(timeout)s — messages so far: \(manager.messages.count)")
            return false
        }
        return true
    }

    /// Relative paths of all regular files under `root`.
    static func listAllFiles(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url.relativeTo(root))
            }
        }
        return files.sorted()
    }

    /// Prints a [HARNESS] check line — used for scenario diagnostics.
    static func logCheck(_ passed: Bool, label: String) {
        print("[HARNESS] \(passed ? "✓" : "✗") \(label)")
    }

    /// Verifies no raw tool-call markup leaked into committed assistant text.
    static func assertNoRawToolMarkup(_ manager: ConversationManager, file: StaticString = #filePath, line: UInt = #line) {
        for msg in manager.messages where msg.role == .assistant && !msg.isDraft {
            let content = msg.content.lowercased()
            let bad = ["<tool_call>", "<tool_code>", "<function=", "[tool_call]",
                        "<invoke name=", "call:read_file", "call:search_project"]
            for pattern in bad {
                XCTAssertFalse(content.contains(pattern),
                    "Raw tool markup '\(pattern)' leaked into assistant message",
                    file: file, line: line)
            }
        }
    }
}
