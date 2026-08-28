//
//  CommandRegistry.swift
//  Compass
//
//  Created by Jack Trefon on 21/12/2025.
//

import Foundation

/// A unique identifier for a command, e.g., "editor.save" or "git.commit".
public struct CommandID: Hashable, ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public var description: String { value }
}

public struct EmptyCommandArgs: Codable, Sendable {
    public init() {}
}

public struct TypedCommand<Args: Codable & Sendable>: Hashable, Sendable {
    public let id: CommandID

    public init(_ id: CommandID) {
        self.id = id
    }
}

/// Protocol for any handler that can execute a command.
/// Protocol for command handlers that can execute commands with arguments.
@MainActor
public protocol CommandHandler {
    /// Execute the command with the provided arguments.
    /// - Parameter args: Command arguments as key-value pairs
    func execute(args: [String: Any]) async throws
}

/// A closure-based command handler for convenience.
@MainActor
public final class ClosureCommandHandler: CommandHandler {
    private let action: @MainActor @Sendable ([String: Any]) async throws -> Void

    public init(_ action: @escaping @MainActor @Sendable ([String: Any]) async throws -> Void) {
        self.action = action
    }

    /// Execute the command with the provided arguments.
    /// - Parameter args: Command arguments as key-value pairs
    public func execute(args: [String: Any]) async throws {
        try await action(args)
    }
}

/// The centralized registry for all application commands.
/// This allows plugins to register behavior and the UI to trigger it blindly.
@MainActor
public final class CommandRegistry {
    private var handlers: [CommandID: CommandHandler] = [:]

    public init() {}

    /// Registers a handler for a command.
    /// Allows overwriting (Last-Writer-Wins) which enables "Hijacking".
    /// - Parameters:
    ///   - command: The command identifier
    ///   - handler: The handler that will execute the command
    public func register(command: CommandID, handler: CommandHandler) {
        handlers[command] = handler
    }

    /// Registers a closure-based handler for a command.
    /// - Parameters:
    ///   - command: The command identifier
    ///   - action: The closure to execute when the command is triggered
    public func register(
        command: CommandID,
        action: @escaping @MainActor @Sendable ([String: Any]) async throws -> Void
    ) {
        register(command: command, handler: ClosureCommandHandler(action))
    }

    public func register<Args: Codable & Sendable>(
        command: TypedCommand<Args>,
        action: @escaping @MainActor @Sendable (Args) async throws -> Void
    ) {
        register(command: command.id) { dict in
            let args = try Self.decode(Args.self, from: dict)
            try await action(args)
        }
    }

    public func unregister(command: CommandID) {
        handlers.removeValue(forKey: command)
    }

    public func registeredCommandIDs() -> [CommandID] {
        handlers.keys.sorted { $0.value < $1.value }
    }

    public func execute(_ command: CommandID, args: [String: Any] = [:]) async throws {
        guard let handler = handlers[command] else {
            throw AppError.commandNotFound(command.value)
        }

        try await handler.execute(args: args)
    }

    public func execute<Args: Codable & Sendable>(_ command: TypedCommand<Args>, args: Args) async throws {
        try await execute(command.id, args: Self.encode(args))
    }

    public func execute(_ command: TypedCommand<EmptyCommandArgs>) async throws {
        try await execute(command.id)
    }

    private static func decode<T: Decodable>(_: T.Type, from dict: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if let dict = json as? [String: Any] {
            return dict
        }
        return [:]
    }
}

public extension CommandRegistry {
    func executeResult(
        _ command: CommandID,
        args: [String: Any] = [:]
    ) async -> Result<Void, AppError> {
        do {
            try await execute(command, args: args)
            return .success(())
        } catch {
            if let appError = error as? AppError {
                return .failure(appError)
            }
            return .failure(
                .unknown(
                    "CommandRegistry.execute failed: \(error.localizedDescription)"
                )
            )
        }
    }

    func executeResult<Args: Codable & Sendable>(
        _ command: TypedCommand<Args>,
        args: Args
    ) async -> Result<Void, AppError> {
        do {
            try await execute(command, args: args)
            return .success(())
        } catch {
            if let appError = error as? AppError {
                return .failure(appError)
            }
            return .failure(
                .unknown(
                    "CommandRegistry.execute failed: \(error.localizedDescription)"
                )
            )
        }
    }
}
