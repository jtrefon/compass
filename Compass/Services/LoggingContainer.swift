import Foundation

/// Owns the 10 log/project-root fan-out that previously lived in
/// `DependencyContainer` (727 lines) and `ConversationManager` (logging setup).
///
/// **Design rationale:**
/// - Single `setProjectRoot` fan-out replaces `ConversationManager.updateProjectRoot`
///   touching 10 `.shared` stores and `DependencyContainer.configureLoggingStores`.
/// - `Sendable` so it can be held by `@MainActor` containers and called from
///   background `Task.detached` without capturing 10 singletons individually.
struct LoggingContainer: Sendable {
    func setProjectRoot(_ root: URL) async {
        await AIToolTraceLogger.shared.setProjectRoot(root)
        await AppLogger.shared.setProjectRoot(root)
        FIMTraceLogger.shared.setProjectRoot(root)
        await ConversationLogStore.shared.setProjectRoot(root)
        await ExecutionLogStore.shared.setProjectRoot(root)
        await ConversationIndexStore.shared.setProjectRoot(root)
        await ConversationPlanStore.shared.setProjectRoot(root)
        await PatchSetStore.shared.setProjectRoot(root)
        await OrchestrationRunStore.shared.setProjectRoot(root)
        await DiagnosticsLogger.shared.setup(projectRoot: root)
        await UIRenderDiagnostics.shared.setup(projectRoot: root)
    }
}
