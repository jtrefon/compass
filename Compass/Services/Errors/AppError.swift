//
//  AppError.swift
//  Compass
//
//  Created by AI Assistant on 20/12/2025.
//

import Foundation

/// Application-specific error types for better error handling
public enum AppError: LocalizedError {
    case fileOperationFailed(String, underlying: Error)
    case invalidFilePath(String)
    case fileNotFound(String)
    case permissionDenied(String)
    case networkError(String)
    case aiServiceError(String)
    case terminalError(String)
    case commandNotFound(String)
    case promptLoadingFailed(String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .fileOperationFailed(let operation, let underlying):
            return "File operation '\(operation)' failed: \(underlying.localizedDescription)"
        case .invalidFilePath(let path):
            return "Invalid file path: \(path)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .permissionDenied(let resource):
            return "Permission denied: \(resource)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .aiServiceError(let message):
            return "AI service error: \(message)"
        case .terminalError(let message):
            return "Terminal error: \(message)"
        case .commandNotFound(let commandId):
            return "Command not found: \(commandId)"
        case .promptLoadingFailed(let message):
            return "Prompt loading failed: \(message)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .fileOperationFailed:
            return "Check file permissions and try again."
        case .invalidFilePath:
            return "Please provide a valid file path."
        case .fileNotFound:
            return "Check if the file exists and the path is correct."
        case .permissionDenied:
            return "Grant necessary permissions or try with administrator access."
        case .networkError:
            return "Check your internet connection and try again."
        case .aiServiceError:
            return "Check AI service configuration and try again."
        case .terminalError:
            return "Restart terminal session or check shell configuration."
        case .commandNotFound:
            return "Restart the application. If the issue persists, report it as a bug."
        case .promptLoadingFailed:
            return "Verify the external prompt markdown files are present and readable."
        case .unknown:
            return "Restart the application and try again."
        }
    }

    public var severity: ErrorSeverity {
        switch self {
        case .fileOperationFailed, .invalidFilePath, .fileNotFound, .commandNotFound:
            return .warning
        case .permissionDenied, .networkError, .aiServiceError, .terminalError, .promptLoadingFailed:
            return .error
        case .unknown:
            return .critical
        }
    }
}
