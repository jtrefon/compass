import Foundation
import Combine

/// App-wide single source of truth for the active project root directory.
///
/// All subsystems that depend on the project path — terminal working directory,
/// file tree root, agentic sandboxing (`PathValidator`), codebase index,
/// conversation scoping — should read from this registry to guarantee
/// consistency.  Write access is restricted so the value can only be changed
/// through the official lifecycle path (see `WorkspaceLifecycleCoordinator`).
///
/// ## Seeding
///
/// The registry starts as `nil`.  `AppState.init` seeds it synchronously from
/// the workspace's current directory so that views (terminal, file tree, etc.)
/// see the correct path before the Combine-based observation pipeline fires.
/// When the user opens or switches projects, ``set(_:)`` replaces the value.
///
/// ## Fan-out
///
/// Subscribe via the `@Published` publisher:
/// ```swift
/// let root = ProjectRootRegistry.shared.current          // sync read
/// ProjectRootRegistry.shared.$current.dropFirst().sink { … }  // changes
/// ```
@MainActor
final class ProjectRootRegistry: ObservableObject {
    static let shared = ProjectRootRegistry()

    /// The current project root, or `nil` if no project is open.
    @Published private(set) var current: URL?

    private init() {}

    /// Called by `WorkspaceLifecycleCoordinator` when the workspace root changes.
    /// Standardises the URL (resolves symlinks, standardises path) so consumers
    /// always see the same canonical representation.
    func set(_ url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if current != canonical {
            current = canonical
        }
    }

    /// Called when all projects are closed.
    func clear() {
        current = nil
    }
}
