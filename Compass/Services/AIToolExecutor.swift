//
//  AIToolExecutor.swift
//  Compass
//
//  Created by Cascade on 02/01/2026.
//

import Foundation
import SwiftUI

/// Handles the execution of AI tools and manages the result reporting.
/// Refactored to use specialized services for better maintainability.
@MainActor
public final class AIToolExecutor {
    // Specialized services
    let argumentResolver: ToolArgumentResolver
    let scheduler: ToolScheduler
    let eventBus: EventBusProtocol?
    var preventionEngine: PreWritePreventionEngine
    
    /// Activity coordinator for power management during tool execution
    let activityCoordinator: AgentActivityCoordinating?

    public init(
        fileSystemService: FileSystemService,
        errorManager: any ErrorManagerProtocol,
        projectRoot: URL,
        eventBus: EventBusProtocol? = nil,
        defaultFilePathProvider: (@MainActor () -> String?)? = nil,
        activityCoordinator: AgentActivityCoordinating? = nil
    ) {
        // Initialize specialized services
        self.argumentResolver = ToolArgumentResolver(
            fileSystemService: fileSystemService,
            projectRoot: projectRoot,
            defaultFilePathProvider: defaultFilePathProvider
        )
        self.scheduler = ToolScheduler()
        self.eventBus = eventBus
        self.preventionEngine = PreWritePreventionEngine(
            fileSystemService: fileSystemService,
            projectRoot: projectRoot
        )
        self.activityCoordinator = activityCoordinator
    }

    func updateProjectRoot(_ newRoot: URL) {
        argumentResolver.updateProjectRoot(newRoot)
        preventionEngine.updateProjectRoot(newRoot)
    }

    // MARK: - Helper Methods (using specialized services)

    func isWriteLikeTool(_ toolName: String) -> Bool {
        return argumentResolver.isWriteLikeTool(toolName)
    }

    func pathKey(for toolCall: AIToolCall) -> String {
        return argumentResolver.pathKey(for: toolCall)
    }

    func resolveTargetFile(for toolCall: AIToolCall) -> String? {
        return argumentResolver.resolveTargetFile(for: toolCall)
    }
}
