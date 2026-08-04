# UI Scaling Issue Fix Plan

## Problem Description
- Bottom status bar (IndexStatusBarView) is off-screen
- Mode indicator (agent/read-only) in AIChatPanel is incorrectly scaled
- UI is incorrectly scaled, content not fitting within window bounds

## Root Cause Analysis

### Primary Issue: Missing Safe Area Constraints
The main layout in [`ContentView.swift`](compass/ContentView.swift:49-58) uses a simple VStack without proper frame constraints:

```swift
private var mainLayout: some View {
    VStack(spacing: 0) {
        WindowSetupView(appState: appState)
        workspaceLayout
        IndexStatusBarView(...)
    }
}
```

This VStack has no frame constraints to ensure it respects the window's safe area. When the window is resized or on certain display configurations, the content overflows because:
1. No `frame(maxHeight: .infinity)` constraint on mainLayout
2. No GeometryReader to calculate available space properly
3. The IndexStatusBarView (height: 24) is placed at the bottom but not anchored to safe area

### Secondary Issues
1. **Window Resizability**: `.windowResizability(.automatic)` in [`compassApp.swift`](compass/compassApp.swift:383) may cause content sizing issues
2. **Toolbar Style**: `.windowToolbarStyle(.unifiedCompact)` affects window chrome calculations
3. **No safe area padding**: The root view doesn't use `.safeAreaInset()` to position the status bar

## Fix Plan

### Step 1: Modify ContentView.swift - Add Safe Area Constraints

**Current code (lines 49-58):**
```swift
private var mainLayout: some View {
    VStack(spacing: 0) {
        WindowSetupView(appState: appState)
        workspaceLayout
        IndexStatusBarView(...)
    }
}
```

**Fix:** Add frame constraints and safe area handling:
```swift
private var mainLayout: some View {
    VStack(spacing: 0) {
        WindowSetupView(appState: appState)
        workspaceLayout
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .bottom) {
        IndexStatusBarView(
            appState: appState,
            codebaseIndexProvider: { appState.codebaseIndex },
            eventBus: appState.eventBus
        )
    }
}
```

### Step 2: Verify AIChatPanel Mode Selector Position

The mode selector in [`AIChatPanel.swift`](compass/Components/AIChatPanel.swift:149-173) is at the bottom of the chat panel. This should also respect safe areas. The panel already uses `.frame(maxWidth: .infinity, maxHeight: .infinity)` on line 125, which should be sufficient, but verify it fits properly.

### Step 3: Verify Window Configuration

The window configuration in [`compassApp.swift`](compass/compassApp.swift:62-101) should remain as-is for now, but we may need to adjust `.windowResizability(.automatic)` if the issue persists.

## Implementation Steps

1. **Edit ContentView.swift** - Replace the mainLayout property to use safeAreaInset for the IndexStatusBarView
2. **Test the fix** - Verify the status bar is visible and properly positioned
3. **If needed** - Adjust AIChatPanel similarly or modify window configuration

## Risk Assessment
- **Low Risk**: The changes are purely layout-related using SwiftUI best practices
- **Compatibility**: safeAreaInset is available in macOS 13+ (our deployment target should support this)
- **No breaking changes**: The visual appearance should remain the same, just properly constrained to safe areas
