import Foundation

/// Published when the agent (or user tooling) modifies the dynamic exclusion
/// list via `exclude_from_index`. Consumers re-enumerate / reindex so the
/// change applies without reopening the project.
public struct IndexExclusionsChangedEvent: Event {
    public let added: [String]
    public let removed: [String]

    public init(added: [String], removed: [String]) {
        self.added = added
        self.removed = removed
    }
}
