//
//  ConversationLogger.swift
//  Compass
//
//  Created by AI Assistant on 12/01/2026.
//

import Foundation

/// Handles logging for conversation-related events
@MainActor
struct ConversationLogger {

    // MARK: - Public Methods

    /// Logs a user message
    func logUserMessage(_ context: ConversationUserMessageLogContext) {
        let conversationId = context.identity.conversationId
        let projectRootPath = context.identity.projectRootPath
        let mode = context.details.mode
        let text = context.details.text
        let hasSelectionContext = context.details.hasSelectionContext
        
        Task.detached(priority: .utility) {
            await AIToolTraceLogger.shared.log(
                type: "chat.user_message",
                data: [
                    "mode": mode,
                    "projectRoot": projectRootPath,
                    "inputLength": text.count,
                    "hasSelectionContext": hasSelectionContext
                ]
            )

            await AppLogger.shared.info(
                category: .conversation,
                message: "chat.user_message",
                context: AppLogger.LogCallContext(metadata: [
                    "conversationId": conversationId,
                    "mode": mode,
                    "projectRoot": projectRootPath,
                    "inputLength": text.count,
                    "hasSelectionContext": hasSelectionContext
                ])
            )
            await ConversationLogStore.shared.append(
                conversationId: conversationId,
                type: "chat.user_message",
                data: [
                    "content": text,
                    "hasSelectionContext": hasSelectionContext
                ]
            )
        }
    }

    /// Logs an AI request start
    func logAIRequestStart(mode: String, historyCount: Int) {
        let modeValue = mode
        let historyValue = historyCount
        Task.detached(priority: .utility) {
            await AIToolTraceLogger.shared.log(
                type: "chat.ai_request_start",
                data: [
                    "mode": modeValue,
                    "historyCount": historyValue
                ]
            )
        }
    }

    /// Logs a chat error
    func logChatError(
        conversationId: String,
        errorDescription: String
    ) {
        let convId = conversationId
        let errorDesc = errorDescription
        Task.detached(priority: .utility) {
            await AppLogger.shared.error(
                category: .error,
                message: "chat.error",
                context: AppLogger.LogCallContext(metadata: [
                    "conversationId": convId,
                    "error": errorDesc
                ])
            )
            await ConversationLogStore.shared.append(
                conversationId: convId,
                type: "chat.error",
                data: [
                    "error": errorDesc
                ]
            )
        }
    }

    /// Logs a conversation start
    func logConversationStart(
        conversationId: String,
        mode: String,
        projectRootPath: String,
        previousConversationId: String? = nil
    ) {
        let convId = conversationId
        let modeValue = mode
        let projectPath = projectRootPath
        let prevId = previousConversationId
        
        Task.detached(priority: .utility) {
            var metadata: [String: Any] = [
                "conversationId": convId,
                "mode": modeValue,
                "projectRoot": projectPath
            ]
            if let previousId = prevId {
                metadata["previousConversationId"] = previousId
            }

            await AppLogger.shared.info(
                category: .conversation,
                message: "conversation.start",
                context: AppLogger.LogCallContext(metadata: metadata)
            )
            await ConversationLogStore.shared.append(
                conversationId: convId,
                type: "conversation.start",
                data: [
                    "mode": modeValue,
                    "projectRoot": projectPath,
                    "previousConversationId": prevId as Any
                ]
            )
            await ConversationIndexStore.shared.appendStart(
                conversationId: convId,
                mode: modeValue,
                projectRootPath: projectPath
            )
        }
    }

    /// Initializes logging stores for a project root
    func initializeProjectRoot(_ root: URL, eventBus: EventBusProtocol? = nil) {
        let projectRoot = root
        let bus = eventBus
        Task.detached(priority: .utility) {
            // CRITICAL: Set project root for all loggers including AI trace
            await AIToolTraceLogger.shared.setProjectRoot(projectRoot)
            await RAGTraceLogger.shared.setProjectRoot(projectRoot)
            await VectorStoreIngestionTracker.shared.setProjectRoot(projectRoot)
            await AppLogger.shared.setProjectRoot(projectRoot)
            await CrashReporter.shared.setProjectRoot(projectRoot)
            if let bus {
                await ConversationLogStore.shared.setEventBus(bus)
            }
            await ConversationLogStore.shared.setProjectRoot(projectRoot)
            await ExecutionLogStore.shared.setProjectRoot(projectRoot)
            await ConversationIndexStore.shared.setProjectRoot(projectRoot)
            await ConversationPlanStore.shared.setProjectRoot(projectRoot)
            await PatchSetStore.shared.setProjectRoot(projectRoot)

            await AppLogger.shared.info(
                category: .app,
                message: "logging.project_root_set",
                context: AppLogger.LogCallContext(metadata: [
                    "projectRoot": projectRoot.path
                ])
            )
        }
    }

    /// Logs trace start
    func logTraceStart(mode: String, projectRootPath: String, logPath: String) {
        let modeValue = mode
        let projectPath = projectRootPath
        let logFilePath = logPath
        Task.detached(priority: .utility) {
            await AIToolTraceLogger.shared.log(
                type: "trace.start",
                data: [
                    "logFile": logFilePath,
                    "mode": modeValue,
                    "projectRoot": projectPath
                ]
            )
        }
    }
}
