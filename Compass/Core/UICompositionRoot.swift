import Foundation

@MainActor
enum UICompositionRoot {
    private static var initializedRegistries = Set<ObjectIdentifier>()
    private static func logToFile(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/Compass-startup.log")
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func compose(appState: AppState, didInitializeCorePlugin: inout Bool) {
        let registryID = ObjectIdentifier(appState.uiRegistry)
        if !didInitializeCorePlugin && !initializedRegistries.contains(registryID) {
            CorePlugin.initialize(registry: appState.uiRegistry, context: appState)
            initializedRegistries.insert(registryID)
            didInitializeCorePlugin = true
        } else if initializedRegistries.contains(registryID) {
            didInitializeCorePlugin = true
        }

        let issues = validate(registry: appState.uiRegistry, ui: appState.ui)
        appState.uiCompositionIssues = issues
        appState.isUIReady = issues.isEmpty

        if AppRuntimeEnvironment.launchContext.isUITesting {
            let sidebarCount = appState.uiRegistry.views(for: .sidebarLeft).count
            let bottomCount = appState.uiRegistry.views(for: .panelBottom).count
            let rightCount = appState.uiRegistry.views(for: .panelRight).count
            let msg = "[UICompositionRoot][UITest] visible(sidebar=\(appState.ui.isSidebarVisible), terminal=\(appState.ui.isTerminalVisible), chat=\(appState.ui.isAIChatVisible)) views(sidebar=\(sidebarCount), bottom=\(bottomCount), right=\(rightCount)) ready=\(appState.isUIReady)"
            logToFile(msg)
        }

        if !issues.isEmpty {
        }
    }

    static func validate(registry: UIRegistry, ui: UIStateManager) -> [String] {
        var issues: [String] = []

        let sidebarViews = registry.views(for: .sidebarLeft)
        let bottomViews = registry.views(for: .panelBottom)
        let rightViews = registry.views(for: .panelRight)

        if ui.isSidebarVisible && sidebarViews.isEmpty {
            issues.append("Missing sidebarLeft view while sidebar is visible")
        }

        let bottomNames = Set(bottomViews.map(\.name))
        let requiredBottom: Set<String> = [
            AppConstants.Overlay.internalTerminalPanelName,
            "Internal.Logs",
            "Internal.Problems"
        ]

        if ui.isTerminalVisible && !requiredBottom.isSubset(of: bottomNames) {
            issues.append("Missing required bottom panel plugins")
        }

        if ui.isAIChatVisible && rightViews.isEmpty {
            issues.append("Missing panelRight view while AI chat is visible")
        }

        return issues
    }
}
