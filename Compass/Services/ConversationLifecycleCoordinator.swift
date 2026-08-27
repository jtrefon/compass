import Combine
import Foundation

/// Owns power-management observation and logging setup that previously lived in
/// `ConversationManager` (832 lines). The manager now holds a single
/// `lifecycleCoordinator` and forwards `setupPowerObservation` / `initializeLogging`.
///
/// **Design rationale:**
/// - Power (`AgentActivityCoordinator` + `isSending` publisher) and logging
///   (`ConversationLogger` + 8 `LogStore.shared.setProjectRoot`) are orthogonal
///   to send/session/streaming — extracting them keeps the manager a thin
///   facade.
/// - `@MainActor` because `ConversationLogger` and `AgentActivityCoordinator`
///   are main-actor confined and `isSending` is a `Published` on main.
@MainActor
final class ConversationLifecycleCoordinator {

    // MARK: - Dependencies

    private let conversationLogger: ConversationLogger
    private let activityCoordinator: AgentActivityCoordinating?
    private var apiSendingActivityToken: AgentActivityToken?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        conversationLogger: ConversationLogger,
        activityCoordinator: AgentActivityCoordinating?
    ) {
        self.conversationLogger = conversationLogger
        self.activityCoordinator = activityCoordinator
    }

    // MARK: - Power Management

    /// Observes `isSending` and begins/ends the `apiSending` activity token.
    func observeIsSending(_ publisher: Published<Bool>.Publisher) {
        publisher
            .removeDuplicates()
            .sink { [weak self] isSending in
                guard let self, let coordinator = self.activityCoordinator else { return }
                if isSending {
                    self.apiSendingActivityToken = coordinator.beginActivity(type: .apiSending)
                } else {
                    self.apiSendingActivityToken?.end()
                    self.apiSendingActivityToken = nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Logging

    func initializeLogging(root: URL, eventBus: any EventBusProtocol) {
        conversationLogger.initializeProjectRoot(root, eventBus: eventBus)
    }

    func startTraceLogging(root: URL, currentMode: AIMode) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let logPath = await AIToolTraceLogger.shared.currentLogFilePath()
            await self.conversationLogger.logTraceStart(
                mode: await currentMode.rawValue,
                projectRootPath: await root.path,
                logPath: logPath ?? ""
            )
        }
    }

    func configureLoggingStores(root: URL) {
        Task.detached(priority: .utility) {
            await AIToolTraceLogger.shared.setProjectRoot(root)
            await AppLogger.shared.setProjectRoot(root)
            FIMTraceLogger.shared.setProjectRoot(root)
            await ConversationLogStore.shared.setProjectRoot(root)
            await ExecutionLogStore.shared.setProjectRoot(root)
            await ConversationIndexStore.shared.setProjectRoot(root)
            await ConversationPlanStore.shared.setProjectRoot(root)
            await PatchSetStore.shared.setProjectRoot(root)
            await OrchestrationRunStore.shared.setProjectRoot(root)
        }
    }

    func logConversationStart(conversationId: String, mode: String, projectRoot: URL, previousId: String? = nil) {
        conversationLogger.logConversationStart(
            conversationId: conversationId,
            mode: mode,
            projectRootPath: projectRoot.path,
            previousConversationId: previousId
        )
    }
}
