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
    /// - Returns: A Cancellable that can be stored to manage subscription lifecycle.
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
///
/// **Design rationale:**
/// - `final class` with a single lock protecting all mutable state. While an
///   `@MainActor` or `actor` conversion would be ideal, `subscribe` must return
///   an `AnyCancellable` synchronously and is called from many non-async
///   contexts (init, start) — actor isolation would cascade `await` through
///   ~35 call sites. A lock keeps the change contained and the public API
///   unchanged.
/// - `@unchecked Sendable` is safe here: every access to `subjects` and
///   `registrations` goes through `lock`. The lock is released before
///   `subject.send(event)` to prevent deadlock if a subscriber re-enters
///   publish/subscribe.
/// - **Cleanup fixes unbounded growth:** the old implementation retained
///   `PassthroughSubject`s forever. Now each subscription is tracked by UUID;
///   when its `AnyCancellable` deallocates, the subject is removed if no other
///   subscriber holds it.
public final class EventBus: EventBusProtocol, @unchecked Sendable {
    private var subjects: [String: Any] = [:]
    private var registrations: [String: [UUID: AnyCancellable]] = [:]
    private let lock = NSLock()

    public init() {}

    public func publish<E: Event>(_ event: E) {
        let key = String(describing: E.self)
        let subject: PassthroughSubject<E, Never>?
        lock.lock()
        subject = subjects[key] as? PassthroughSubject<E, Never>
        lock.unlock()

        subject?.send(event)
    }

    public func subscribe<E: Event>(to eventType: E.Type, handler: @escaping (E) -> Void) -> AnyCancellable {
        let key = String(describing: E.self)
        let id = UUID()

        lock.lock()
        let subject: PassthroughSubject<E, Never>
        if let existing = subjects[key] as? PassthroughSubject<E, Never> {
            subject = existing
        } else {
            subject = PassthroughSubject<E, Never>()
            subjects[key] = subject
        }
        lock.unlock()

        let cancellable = subject
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: handler)

        lock.lock()
        if registrations[key] == nil { registrations[key] = [:] }
        registrations[key]?[id] = cancellable
        lock.unlock()

        return AnyCancellable { [weak self] in
            self?.removeRegistration(key: key, id: id)
        }
    }

    private func removeRegistration(key: String, id: UUID) {
        lock.lock()
        registrations[key]?.removeValue(forKey: id)
        if registrations[key]?.isEmpty ?? true {
            registrations[key] = nil
            subjects.removeValue(forKey: key)
        }
        lock.unlock()
    }
}

// MARK: - Event types

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
