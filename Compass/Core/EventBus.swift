//
//  EventBus.swift
//  Compass
//
//  Created by Jack Trefon on 21/12/2025.
//

import Foundation
import Combine

/// Marker protocol for all events in the system.
/// Events should be immutable structs containing data about what happened.
public protocol Event { }

/// Protocol for the system-wide Event Bus.
public protocol EventBusProtocol: Sendable {
    /// Publishes an event to all subscribers.
    func publish<E: Event>(_ event: E)

    /// Subscribes to a specific type of event.
    /// - Returns: A Cancellable generic that can be stored to manage subscription lifecycle.
    func subscribe<E: Event>(to eventType: E.Type, handler: @escaping (E) -> Void) -> AnyCancellable
}

/// No-op bus for default wiring (test generators, optional event plumbing).
public struct NoOpEventBus: EventBusProtocol {
    public init() {}

    public func publish<E: Event>(_ event: E) {}

    public func subscribe<E: Event>(to eventType: E.Type, handler: @escaping (E) -> Void) -> AnyCancellable {
        AnyCancellable {}
    }
}

/// The concrete implementation of the Event Bus using Combine.
/// This acts as the central nervous system of the IDE.
/// Thread-safe but NOT isolated to @MainActor to avoid blocking background publishers.
// Thread safety: `subjects` dictionary is protected by `lock`. The lock is
// released before `subject.send(event)` to prevent deadlock if a subscriber
// re-enters publish/subscribe. Combine's PassthroughSubject.send() is
// thread-safe and re-entrant.
public final class EventBus: EventBusProtocol, @unchecked Sendable {
    // We store PassthroughSubjects for each Event type name.
    // Using String keys (type name) allows decoupled storage.
    private var subjects: [String: Any] = [:]
    private let lock = NSLock()

    // Log sampling to avoid spawning a Task per event on hot paths
    private let logSampleRate: UInt64 = 100
    private var publishCounter: UInt64 = 0
    private var subscribeCounter: UInt64 = 0
    private let statsLock = NSLock()

    public init() {}

    public func publish<E: Event>(_ event: E) {
        let key = String(describing: E.self)

        // Log only every Nth publish to avoid spawning Tasks on hot paths
        statsLock.lock()
        publishCounter += 1
        let shouldLog = (publishCounter % logSampleRate == 0)
        statsLock.unlock()
        if shouldLog {
            Task {
                await AppLogger.shared.debug(
                    category: .eventBus,
                    message: "event.publish",
                    context: AppLogger.LogCallContext(metadata: [
                        "eventType": key,
                        "publishCount": String(publishCounter)
                    ])
                )
            }
        }
        
        let subject: PassthroughSubject<E, Never>?
        lock.lock()
        subject = subjects[key] as? PassthroughSubject<E, Never>
        lock.unlock()
        
        subject?.send(event)
    }

    public func subscribe<E: Event>(to eventType: E.Type, handler: @escaping (E) -> Void) -> AnyCancellable {
        let key = String(describing: E.self)

        // Log only every Nth subscribe
        statsLock.lock()
        subscribeCounter += 1
        let shouldLog = (subscribeCounter % logSampleRate == 0)
        statsLock.unlock()
        if shouldLog {
            Task {
                await AppLogger.shared.debug(
                    category: .eventBus,
                    message: "event.subscribe",
                    context: AppLogger.LogCallContext(metadata: [
                        "eventType": key
                    ])
                )
            }
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        let subject: PassthroughSubject<E, Never>

        if let existing = subjects[key] as? PassthroughSubject<E, Never> {
            subject = existing
        } else {
            subject = PassthroughSubject<E, Never>()
            subjects[key] = subject
        }

        // Deliver events on main thread for UI updates
        return subject
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: handler)
    }
}

public struct LocalModelStreamingChunkEvent: Event {
    public let runId: String
    public let chunk: String

    public init(runId: String, chunk: String) {
        self.runId = runId
        self.chunk = chunk
    }
}

public struct LocalModelStreamingReasoningChunkEvent: Event {
    public let runId: String
    public let chunk: String

    public init(runId: String, chunk: String) {
        self.runId = runId
        self.chunk = chunk
    }
}

/// Emitted whenever the in-memory context is *altered* for the model — i.e. a
/// compaction checkpoint is created (the legacy silent behavior that dropped the
/// user's task goal). Observing this event makes context alteration explicit and
/// auditable, closing the "silent mutation" gap. The canonical chain remains
/// append-only; this only records that a derived view was summarized.
/// Emitted per streaming chunk with an estimated running token count.
/// Lets the status bar show smooth context growth during generation.
/// When `isFinal=true` the streaming session is complete and the estimate
/// should be accumulated into the permanent total.
public struct StreamingContextUsageEvent: Event {
    public let runId: String
    public let estimatedPromptTokens: Int
    public let isFinal: Bool

    public init(runId: String, estimatedPromptTokens: Int, isFinal: Bool = false) {
        self.runId = runId
        self.estimatedPromptTokens = estimatedPromptTokens
        self.isFinal = isFinal
    }
}

/// Emitted when the sliding-window roll drops older turns from the model view
/// (benign: the canonical chain is untouched, the goal anchor is preserved).
/// Useful for telemetry on how often long sessions exceed the window.
