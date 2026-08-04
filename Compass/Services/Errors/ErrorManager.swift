//
//  ErrorManager.swift
//  Compass
//
//  Created by AI Assistant on 20/12/2025.
//

import SwiftUI
import Combine

/// Centralized error management for the application
@MainActor
class ErrorManager: ObservableObject, ErrorManagerProtocol {
    @Published var currentError: AppError?
    @Published var showErrorAlert: Bool = false
    @Published var errorHistory: [AppError] = []

    private var pendingAutoDismissTask: Task<Void, Never>?

    private let maxHistoryCount = AppConstantsFileSystem.maxHistoryCount

    /// Handle an error with appropriate UI feedback
    func handle(_ error: AppError) {
        handle(error, context: ErrorHandlingContext(
            operation: "ErrorManager.handle(AppError)",
            file: #fileID,
            function: #function,
            line: #line
        ))
    }

    private func handle(_ error: AppError, context: ErrorHandlingContext) {
        pendingAutoDismissTask?.cancel()
        pendingAutoDismissTask = nil

        currentError = error
        showErrorAlert = true

        // Add to history for logging
        errorHistory.append(error)
        if errorHistory.count > maxHistoryCount {
            errorHistory.removeFirst()
        }

        // Log the error
        logError(error, context: context)

        // Auto-dismiss info and warning errors after delay
        if error.severity == .info || error.severity == .warning {
            let targetSeverity = error.severity
            pendingAutoDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(AppConstantsTime.errorAutoDismissDelay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    if self?.currentError?.severity == targetSeverity {
                        self?.dismissError()
                    }
                }
            }
        }
    }

    /// Handle generic Error by converting to AppError
    func handle(_ error: Error, context: String = "") {
        handle(
            error,
            context: context,
            handlingContext: ErrorHandlingContext(
                operation: context,
                file: #fileID,
                function: #function,
                line: #line
            )
        )
    }

    private func handle(
        _ error: Error,
        context: String,
        handlingContext: ErrorHandlingContext
    ) {
        let appError: AppError
        if let appErr = error as? AppError {
            appError = appErr
        } else {
            let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedContext.isEmpty {
                appError = .unknown(error.localizedDescription)
            } else {
                appError = .unknown("\(trimmedContext): \(error.localizedDescription)")
            }
        }
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = trimmedContext.isEmpty ? "ErrorManager.handle(Error)" : trimmedContext
        let handlingContext = ErrorHandlingContext(
            operation: operation,
            file: handlingContext.file,
            function: handlingContext.function,
            line: handlingContext.line
        )
        logCrashCapture(error, context: handlingContext)
        handle(appError, context: handlingContext)
    }

    /// Dismiss current error
    func dismissError() {
        pendingAutoDismissTask?.cancel()
        pendingAutoDismissTask = nil
        currentError = nil
        showErrorAlert = false
    }

    /// Get recent errors for debugging
    func getRecentErrors() -> [AppError] {
        return errorHistory
    }

    /// Clear error history
    func clearErrorHistory() {
        errorHistory.removeAll()
    }

    private func logError(_ error: AppError, context: ErrorHandlingContext) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logMessage = "[\(timestamp)] [\(error.severity)] \(error.localizedDescription)"

        Task {
            await AppLogger.shared.error(
                category: .error,
                message: "app.error",
                context: AppLogger.LogCallContext(metadata: [
                    "severity": String(describing: error.severity),
                    "description": error.localizedDescription,
                    "operation": context.operation
                ])
            )
        }

        logCrashCapture(error, context: context)

        #if DEBUG
        #endif
    }

    private func logCrashCapture(_ error: Error, context: ErrorHandlingContext) {
        Task {
            await CrashReporter.shared.capture(
                error,
                context: CrashReportContext(operation: context.operation),
                metadata: [:],
                file: context.file,
                function: context.function,
                line: context.line
            )
        }
    }
}

/// Extension for easy error handling in other classes
extension ErrorManager {
    /// Wrap error-prone operations with automatic error handling
    func handleError<T>(_ operation: () throws -> T, context: String = "") -> T? {
        do {
            return try operation()
        } catch {
            handle(error, context: context)
            return nil
        }
    }

    /// Async version of error handling
    func handleError<T>(_ operation: () async throws -> T, context: String = "") async -> T? {
        do {
            return try await operation()
        } catch {
            await MainActor.run {
                handle(error, context: context)
            }
            return nil
        }
    }
}
