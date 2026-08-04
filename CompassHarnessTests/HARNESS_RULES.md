# Harness Rules

The harness is a headless XCTest suite that instantiates the real app's `DependencyContainer`, injects a prompt, monitors the full pipeline execution, and validates outcomes via telemetry.

## Cardinal Rule

**The harness implements no application logic.** It orchestrates the existing app implementation via prompts, collects telemetry to understand behavior, and validates results. No code duplication, no disconnect from the real app.

## What the harness does (allowed)

1. Creates `DependencyContainer(launchContext: AppLaunchContext.detect())` — same as the real app
2. Configures a temp project root directory
3. Sets `manager.currentMode = .coder` for agentic tool-using scenarios (`.chat` for read-only scenarios) — mode is a prompt/toolset selector, and setting it is deliberate orchestration, not implementation
4. Calls `manager.sendMessage()` — same method the UI calls
5. Waits for `manager.isSending` to complete (polling loop with deadline)
6. Inspects `manager.messages`, files on disk, and telemetry
7. Validates assertions (files exist, no raw tool markup leaked, context immutability, answer not wiped)

## What the harness does NOT do (prohibited)

1. Does NOT reimplement app logic (its own tool definitions, its own markup strippers, its own file readers) — production types must be called
2. Does NOT mock or stub any app service
3. Does NOT modify the app's execution path in any way
4. Does NOT assert on internal implementation details that the app could refactor freely (assert on observable outcomes)

## Runtime setup

```swift
private func makeRuntime() async throws -> Runtime {
    let projectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("harness_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

    let container = DependencyContainer(launchContext: AppLaunchContext.detect())
    guard let manager = container.conversationManager as? ConversationManager else { throw ... }
    container.workspaceService.currentDirectory = projectRoot
    container.projectCoordinator.configureProject(root: projectRoot)
    manager.currentMode = .coder   // or .chat for read-only scenarios
    try await Task.sleep(nanoseconds: 500_000_000)
    return Runtime(container: container, manager: manager, projectRoot: projectRoot)
}
```

## When a harness test fails

The APP code is wrong, not the harness. Go fix the app.
