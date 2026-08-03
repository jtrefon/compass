# UI Design System Overhaul Plan

## Executive Summary

The app has a partial design system (`GlassStyle.swift`, `AppConstants*.swift`, `SettingsComponents.swift`) but it's inconsistently applied. Over 50% of glass effect usage bypasses the `NativeGlassSurface` abstraction. Spacing, corner radii, and shadows are ad-hoc throughout 80+ component files. Dead code exists (`OverlayHostView`, `liquidGlassCard`). The plan below addresses all 18 issues identified in the review, grouped into 6 phases.

---

## Phase 1 — Foundation: Design Token System

### 1.1 Create a Unified Spacing Scale

**Problem:** Spacing values `{4,6,8,10,12,14,16,20,24,30}` scattered across 80+ files. No 8pt grid compliance.

**Proposed solution:** Replace magic numbers with semantic tokens in `AppConstantsLayout.swift`:

```swift
enum AppConstantsLayout {
    // 8pt grid spacing scale
    static let spacingXXS: CGFloat = 2   // 2pt (rare, only for tight icon clusters)
    static let spacingXS:  CGFloat = 4   // 4pt
    static let spacingSm:  CGFloat = 8   // 8pt — base unit
    static let spacingMd:  CGFloat = 12  // 12pt (8+4, for non-grid exceptions)
    static let spacingLg:  CGFloat = 16  // 16pt — double base
    static let spacingXL:  CGFloat = 24  // 24pt
    static let spacingXXL: CGFloat = 32  // 32pt — quad base
    static let spacingXXXL:CGFloat = 48  // 48pt
}
```

**Files to modify:**
- `compass/Services/AppConstantsLayout.swift` — Add spacing scale
- All component files — Replace hardcoded spacing values (80+ files)

**Migration strategy:** Add the tokens first. Migrate files incrementally by priority: Overlays → Settings → Chat → Editor → Shared.

### 1.2 Create a Semantic Corner Radius Scale

**Problem:** Radii `{6,8,10,12,16,18}` with no semantic mapping.

**Proposed solution:** Add to `AppConstantsLayout.swift`:

```swift
static let cornerSm:  CGFloat = 6   // inline controls, tab buttons
static let cornerMd:  CGFloat = 8   // small containers, popovers
static let cornerLg:  CGFloat = 12  // overlay cards, tool messages
static let cornerXL:  CGFloat = 16  // settings cards, prominent surfaces
```

**Files to modify:**
- `compass/Services/AppConstantsLayout.swift` — Add scale
- All component files using `.cornerRadius()` or `RoundedRectangle(cornerRadius:...)`

### 1.3 Create a Shadow Elevation Scale

**Problem:** Shadows vary wildly: `radius: 30` (OverlayCard), `radius: 10` (LoadingOverlay), custom shadow in InlineAIPopover.

**Proposed solution:** Add to `AppConstantsLayout.swift`:

```swift
struct ShadowElevation {
    let radius: CGFloat
    let y: CGFloat
    let opacity: Double

    static let low    = Self(radius: 4,  y: 1,  opacity: 0.12)
    static let medium = Self(radius: 8,  y: 2,  opacity: 0.15)
    static let high   = Self(radius: 16, y: 4,  opacity: 0.18)
    static let overlay = Self(radius: 30, y: 8, opacity: 0.20)
}

extension View {
    func elevation(_ level: ShadowElevation) -> some View {
        self.shadow(color: .black.opacity(level.opacity), radius: level.radius, x: 0, y: level.y)
    }
}
```

**Files to modify:**
- New: `compass/Services/ShadowElevation.swift` (or inline in AppConstantsLayout)
- `compass/Components/OverlayCard.swift`
- `compass/Components/OverlayScaffold.swift`
- `compass/Components/SettingsComponents.swift`
- `compass/Components/InlineAIPopoverView.swift`
- `compass/compassApp.swift` (LoadingOverlayView)

### 1.4 Create Semantic Color Tokens

**Problem:** Theme system only controls `.preferredColorScheme`. Hardcoded colors in some views (terminal `#00FF00`/`#000000`, provider banners, hover states).

**Proposed solution:** Add `AppConstantsColor.swift`:

```swift
enum AppConstantsColor {
    // Semantic surface colors
    static let surfaceBackground = Color(nsColor: .windowBackgroundColor)
    static let surfaceSidebar = Color(nsColor: .controlBackgroundColor)
    static let surfaceCard = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: .windowBackgroundColor)

    // Semantic text colors
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // Semantic accent
    static let accentDefault = Color.accentColor
    static let accentSubtle = Color.accentColor.opacity(0.12)

    // Terminal defaults (modern, theme-aware)
    static let terminalForeground = Color(nsColor: .textColor)
    static let terminalBackground = Color(nsColor: .textBackgroundColor)
}
```

**Files to modify:**
- New: `compass/Services/AppConstantsColor.swift`
- `compass/Services/AppConstants.swift` — Add typealias
- `compass/Services/UIStateManager.swift` — Update terminal default colors
- All component files — Replace `Color(nsColor: .xxx)` with semantic tokens

---

## Phase 2 — Glass Style Unification

### 2.1 Simplify `GlassStyle.swift`

**Problem:** Two competing glass APIs (`nativeGlassBackground` vs `liquidGlassCard`). The latter is dead code.

**Proposed solution:** Remove `liquidGlassCard()`. Add border/separator as optional parameter to `NativeGlassSurface`:

```swift
enum NativeGlassSurface {
    case header, sidebar, panel, toolbar, popover, sheet

    var material: some ShapeStyle {
        switch self {
        case .header:      .bar
        case .toolbar:     .thickMaterial
        case .sidebar:     .thinMaterial
        case .panel:       .regularMaterial
        case .popover:     .regularMaterial
        case .sheet:       .thickMaterial
        }
    }
}

extension View {
    @ViewBuilder
    func nativeGlassBackground(_ surface: NativeGlassSurface,
                                cornerRadius: CGFloat = 8,
                                showBorder: Bool = false) -> some View {
        self
            .background(surface.material)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(showBorder ? RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.separator.opacity(0.15), lineWidth: 0.5) : nil)
    }
}
```

**Files to modify:**
- `compass/Components/GlassStyle.swift` — Remove `liquidGlassCard`, simplify

### 2.2 Migrate Ad-hoc Glass to `NativeGlassSurface`

**Problem:** `ContentView.swift` and many components use `.glassEffect(.regular, in: ...)` or `.background(.regularMaterial)` directly.

**Files to modify:**

| File | Current | Replace With |
|---|---|---|
| `ContentView.swift:50` | `.glassEffect(.regular, in: .rect(cornerRadius: 0))` | Remove (redundant with window bg) |
| `ContentView.swift:271` | `.glassEffect(.regular, in: .rect(cornerRadius: 0))` | `.nativeGlassBackground(.panel, cornerRadius: 0)` |
| `ContentView.swift:313` | `.glassEffect(.regular, in: .rect(cornerRadius: 16))` | `.nativeGlassBackground(.header, cornerRadius: 16)` |
| `AIChatPanel.swift:203` | `.background(.regularMaterial)` | `.nativeGlassBackground(.panel, cornerRadius: 0)` |
| `EditorTabBar.swift:91` | `.glassEffect(.regular.interactive(), in: ...)` | Keep as-is (uses interactive variant) |
| `ChatInputView.swift:48` | `.glassEffect(.regular, in: RoundedRectangle(...))` | `.nativeGlassBackground(.popover, cornerRadius: 18)` |
| `OverlayCard.swift:11-15` | Direct `.background(.regularMaterial)`+`.cornerRadius()`+`.shadow()` | `.nativeGlassBackground(.panel, cornerRadius: 12)` |

### 2.3 Add `NativeGlassSurface` to `AppConstants` Mapping

Add a mapping to keep all surface styling centralized:

```swift
extension NativeGlassSurface {
    static func forSurface(_ surface: NativeGlassSurface) -> (material: some ShapeStyle, defaultRadius: CGFloat) {
        switch surface {
        case .header:  return (.bar, AppConstantsLayout.cornerSm)
        case .sidebar: return (.thinMaterial, 0)
        case .panel:   return (.regularMaterial, AppConstantsLayout.cornerLg)
        case .toolbar: return (.thickMaterial, AppConstantsLayout.cornerSm)
        case .popover: return (.regularMaterial, AppConstantsLayout.cornerMd)
        case .sheet:   return (.thickMaterial, AppConstantsLayout.cornerLg)
        }
    }
}
```

---

## Phase 3 — Architecture Cleanup

### 3.1 Remove Dead Code: `OverlayHostView`

**Problem:** `ContentView.swift:565-626` defines `OverlayHostView` + `OverlayContainer` but neither is used. Native `.sheet()` modifiers handle all overlays.

**Action:** Delete lines 565-626 from `ContentView.swift`.

**Files to modify:**
- `compass/ContentView.swift:565-626` — Remove `OverlayHostView` struct
- `compass/Components/OverlayContainer.swift` — Remove entire file (dead)
- `compass/Components/OverlayCard.swift` — Review if needed elsewhere, else keep

### 3.2 Remove Dead Code: `liquidGlassCard()`

**Problem:** Defined in `GlassStyle.swift` but never called anywhere.

**Action:** Remove the `liquidGlassCard()` extension method.

**Files to modify:**
- `compass/Components/GlassStyle.swift:56-64`

### 3.3 Fix Bottom Panel Glass Mismatch

**Problem:** Bottom panel header uses `cornerRadius: 16` but content below uses `cornerRadius: 0`, creating visual seam.

**Proposed solution:** The bottom panel header should use `cornerRadius: 0` (full-width bar) with a subtle separator, matching the content area. Or, apply consistent corner treatment.

```swift
// ContentView.swift bottomPanelHeader
.frame(height: AppConstants.Layout.headerHeight)
.glassEffect(.regular, in: .rect(cornerRadius: 0))
.overlay(alignment: .bottom) {
    Rectangle().fill(.separator.opacity(0.25)).frame(height: 1)
}
```

**Files to modify:**
- `compass/ContentView.swift:313-318` — Unify corner radii

### 3.4 Conslidate Bottom Panel Bars

**Problem:** `IndexStatusBarView` (30px) + bottom panel header (30-40px) create dual bars at bottom.

**Proposed solution:** Merge status into bottom panel header, or use a single unified footer strip:

Options:
- **Option A:** Embed index status inline in the bottom panel header via `safeAreaInset`
- **Option B:** Remove `IndexStatusBarView` and show status inline in the bottom panel's leading area
- **Option C:** Keep both but reduce vertical space (current state — acceptable for MVP)

**Recommendation:** Option A — use `.safeAreaInset(edge: .bottom)` for a single combined footer.

**Files to modify:**
- `compass/ContentView.swift` — Restructure `mainLayout` and `terminalPanel`

### 3.5 Consolidate File Tree Coordinators

**Problem:** Multiple coordination patterns: `FileTreeCoordinatorState`, `ModernFileTreeCoordinator`, `FileTreeAppearanceCoordinator`, `FileTreeSearchCoordinator`, `FileTreeDialogCoordinator`.

**Proposed solution:** Per Cardinal Rule 4, audit which coordinators are live vs dead. Remove dead paths. Keep only one coordination architecture.

**Action:** Trace runtime callers of each coordinator. Remove unused ones. This is a separate investigation task.

**Files to modify:** TBD after audit.

---

## Phase 4 — Settings & Components

### 4.1 Migrate Settings to Native `Form`

**Problem:** Custom `VStack + Divider + SettingsCard` instead of `Form + Section`.

**Proposed solution:** Replace outer card layout with macOS-native `Form` where appropriate. Keep `SettingsRow` for the consistent icon+label+control pattern.

```swift
Form {
    Section {
        SettingsRow(...) { control }
        SettingsRow(...) { control }
    } header: {
        Text("Title")
        Text("Subtitle")
    }
}
```

**Files to modify:**
- `compass/Components/SettingsComponents.swift` — Make `Form`-compatible
- `compass/Components/AISettingsTab.swift` — Replace card wrappers
- `compass/Components/GeneralSettingsTab.swift` — Replace card wrappers
- `compass/Components/AgentSettingsTab.swift` — Replace card wrappers

### 4.2 Fix Overlay Card to Use Design System

**Problem:** `OverlayCard.swift` reimplements glass instead of using `nativeGlassBackground()`.

**Proposed solution:**

```swift
struct OverlayCard<Content: View>: View {
    var body: some View {
        content
            .padding(AppConstants.Overlay.containerPadding)
            .nativeGlassBackground(.panel, cornerRadius: AppConstants.Overlay.containerCornerRadius, showBorder: true)
            .elevation(.overlay)
    }
}
```

**Files to modify:**
- `compass/Components/OverlayCard.swift`

### 4.3 Add macOS Toolbar Content

**Problem:** `.windowToolbarStyle(.unifiedCompact)` set but toolbar is empty.

**Proposed solution:** Add primary window-level toolbar items. At minimum, a leading navigation control and trailing AI mode indicator.

```swift
Window("compass", id: "main") {
    AppRootView(...)
}
.windowToolbarStyle(.unifiedCompact)
.toolbar {
    ToolbarItem(placement: .navigation) {
        // Sidebar toggle, back/forward
    }
    ToolbarItemGroup(placement: .primaryAction) {
        // AI mode, run button
    }
}
```

**Files to modify:**
- `compass/compassApp.swift`

### 4.4 Evaluate `.hiddenTitleBar`

**Problem:** Title bar visible, taking vertical space. IDE content benefits from edge-to-edge.

**Proposed solution:** Test with `.windowStyle(.hiddenTitleBar)`. This requires moving window title handling to the toolbar or custom title view. Impact on `WindowSetupView` needs verification.

```swift
Window("compass", id: "main") { ... }
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unifiedCompact)
```

**Files to modify:**
- `compass/compassApp.swift` — Add `.windowStyle(.hiddenTitleBar)`
- `compass/ContentView.swift` — Verify `WindowSetupView` still works
- `compass/Components/WindowSetupView.swift` — May need to set window title via toolbar

---

## Phase 5 — Overlay Architecture

### 5.1 Choose Single Overlay Strategy

**Problem:** Native `.sheet()` + `.popover()` used alongside custom `OverlayContainer` ZStack approach. The custom approach is dead code.

**Decision:** Use native `.sheet()` for all overlays. Remove `OverlayContainer` entirely.

**Files to modify:**
- `compass/Components/OverlayContainer.swift` — Delete
- `compass/ContentView.swift` — Already uses sheets; remove unused import/ref if any

### 5.2 Fix Hardcoded Plugin Name String

**Problem:** `ContentView.swift:295` uses `.replacingOccurrences(of: "Internal.", with: "")` which is fragile.

**Proposed solution:** Add a `displayName` property to `PluginView`:

```swift
protocol PluginView: Identifiable {
    var name: String { get }
    var displayName: String { get }  // default: name.replacingOccurrences(of: "Internal.", with: "")
}
```

**Files to modify:**
- `compass/ContentView.swift:295` — Use `view.displayName`
- Plugin protocol/conformance files

---

## Phase 6 — Terminal & Theme

### 6.1 Update Terminal Default Colors

**Problem:** Default green-on-black retro terminal colors clash with modern material aesthetic.

**Proposed solution:** Default to system-adaptive colors:

```swift
// UIStateManager.swift
@Published var terminalForegroundColor: String = AppConstantsColor.defaultTerminalForeground  // "#D4D4D4"
@Published var terminalBackgroundColor: String = AppConstantsColor.defaultTerminalBackground  // "#1E1E1E"
```

**Files to modify:**
- `compass/Services/UIStateManager.swift:88-89`
- `compass/Services/AppConstantsColor.swift` (new, from Phase 1.4)

### 6.2 Verify Theme Adaptation Completeness

**Problem:** Theme only controls `preferredColorScheme`. Some views may not adapt properly.

**Proposed solution:** Audit all `Color(nsColor: .xxx)` usages to ensure they map to theme-aware system colors. Check:
- Provider issue banners (hardcoded accentColor.opacity)
- Hover state backgrounds (manual opacities)
- Tab bar active/inactive backgrounds

**Files to modify:** Audit pass across all 80+ component files.

---

## Implementation Order & Dependencies

```
Phase 1 (Foundation)
├── 1.1 Spacing Scale ─────────── No deps
├── 1.2 Corner Radius Scale ───── No deps
├── 1.3 Shadow Elevation ──────── No deps
└── 1.4 Color Tokens ──────────── No deps

Phase 2 (Glass Unification)
├── 2.1 Simplify GlassStyle ───── Depends: 1.2 (corner radii)
├── 2.2 Migrate ad-hoc glass ──── Depends: 2.1
└── 2.3 Surface mapping ───────── Depends: 2.1

Phase 3 (Architecture Cleanup)
├── 3.1 Remove OverlayHostView ── No deps (dead code)
├── 3.2 Remove liquidGlassCard ─── No deps (dead code)
├── 3.3 Fix bottom panel glass ─── Depends: 2.2
├── 3.4 Consolidate bottom bars ── Depends: 3.3
└── 3.5 File tree coordinators ─── No deps (audit task)

Phase 4 (Settings & Components)
├── 4.1 Native Form migration ─── Depends: 1.1, 1.4
├── 4.2 OverlayCard fix ───────── Depends: 2.2, 1.3
├── 4.3 Toolbar content ───────── No deps
└── 4.4 hiddenTitleBar eval ───── Depends: 4.3

Phase 5 (Overlay Architecture)
├── 5.1 Choose overlay strategy ── Depends: 3.1
└── 5.2 Fix plugin name ───────── Depends: 5.1

Phase 6 (Terminal & Theme)
├── 6.1 Terminal defaults ─────── Depends: 1.4
└── 6.2 Theme audit ───────────── Depends: 1.4
```

---

## Files Summary

### Files to Create (3)
1. `compass/Services/AppConstantsColor.swift` — Semantic color tokens
2. `compass/Services/ShadowElevation.swift` — (or inline in AppConstantsLayout)

### Files to Delete (2)
1. `compass/Components/OverlayContainer.swift` — Dead code
2. `compass/OverlayHostView` block in ContentView — Dead code

### Files to Modify (5 high-impact, ~30 total across all phases)

| File | Phase | Change |
|---|---|---|
| `compass/Services/AppConstantsLayout.swift` | 1.1, 1.2, 1.3 | Add spacing, corner, shadow tokens |
| `compass/Components/GlassStyle.swift` | 2.1, 2.3 | Simplify, remove liquidGlassCard, add surface mapping |
| `compass/ContentView.swift` | 2.2, 3.1, 3.3, 3.4, 5.2 | Migrate glass, remove dead code, fix bottom panel, fix plugin name |
| `compass/Services/UIStateManager.swift` | 6.1 | Update terminal defaults |
| `compass/Components/OverlayCard.swift` | 4.2 | Use design system |
| `compass/Components/SettingsComponents.swift` | 4.1 | Form compatibility |
| `compass/Components/AIChatPanel.swift` | 2.2 | Migrate glass |
| `compass/Components/ChatInputView.swift` | 2.2 | Migrate glass |
| `compass/Components/EditorTabBar.swift` | 2.2 (review) | Verify glass pattern |
| `compass/Components/SettingsRow.swift` | 4.1 | Ensure Form compatibility |
| `compass/compassApp.swift` | 4.3, 4.4 | Add toolbar items, hiddenTitleBar |
| ~20 other component files | 2.2 | Replace magic spacing/radius values |

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| Spacing migration breaks layout | Medium | Keep old tokens alongside new; migrate one file at a time; visual QA after each |
| `hiddenTitleBar` breaks window chrome | Medium | Feature-flag it; test on macOS 14+ only |
| Form migration changes settings appearance | Low | Compare before/after screenshots |
| Glass migration changes visual depth | Medium | Pixel-compare before/after on light and dark themes |
| Dead code removal has hidden callers | Low | Grep for all references before deleting |
| File tree coordinator removal breaks file tree | Low | Audit callers first |

## Implementation Status (2026-07-04)

| Phase | Status | Notes |
|---|---|---|
| P1 Foundation | ✅ Done | Spacing/corner/shadow/elevation tokens + semantic colors |
| P2 Glass Unification | ✅ Done | Simplified GlassStyle, removed liquidGlassCard, migrated ad-hoc glass |
| P3 Architecture Cleanup | ✅ Done | Removed OverlayHostView + OverlayContainer (dead code), fixed bottom panel |
| P4 Settings & Components | ✅ Done | Added `.windowStyle(.hiddenTitleBar)`, toolbar items deferred |
| P5 Overlay Architecture | ✅ Done | Consolidated to native sheets only |
| P6 Terminal & Theme | ✅ Done | Terminal defaults, theme audit complete |
| Post-audit fixes | ✅ Done | Fixed `Color.white` light-mode breakage, UIService.swift terminal fallback, SettingsStatusPill separator |

### Still Not Done (Deferred)
- **File tree coordinator audit** (3.5) — needs runtime caller tracing
- **Settings Form migration** (4.1) — lower priority, deeper change
- **Window toolbar items** (4.3) — `.toolbar {}` not available on macOS Window Scene directly; needs view-level approach
- **Hardcoded semantic colors** (`.red`, `.green`, `.blue` in ~15 files) — mostly error/status indicators where intentional
- **Separator opacity usages** (~10 files) — low visual impact; `.separator` is already adaptive

## Phase 7 — AppKit Minimization & SwiftUI Unification

### Philosophy
Keep AppKit where it provides **necessary performance or system integration** (NSTextView for code editing, NSOutlineView for large file trees, SwiftTerm for terminal). Migrate everything else to pure SwiftUI to eliminate the legacy bridging tax.

### AppKit Inventory — Keep, Migrate, or Evaluate

#### KEEP (Performance/System Necessity)

| Component | File(s) | Why Must Stay |
|---|---|---|
| Code Editor (`NSTextView`) | `TextViewRepresentable.swift` + coordinators, `CodeEditorTextView.swift` | SwiftUI `TextEditor` lacks syntax highlighting, line numbers, gutter, inline completion, custom selection, large-file performance |
| Line Number Gutter | `LineNumberRulerView.swift` | Custom `NSView` drawing; SwiftUI has no line number equivalent |
| File Tree (`NSOutlineView`) | `ModernFileTreeView.swift`, `FileTreeCellProvider.swift`, coordinators | `NSOutlineView` handles 10,000+ file nodes with lazy loading; SwiftUI `List` would need virtualization |
| Terminal Emulator | `NativeTerminalView.swift`, `Packages/Terminal/SwiftTermView.swift` | `SwiftTerm` is AppKit-based; no SwiftUI terminal widget exists |
| Code Minimap | `MinimapView.swift` (MinimapRepresentable) | Custom `NSView` rendering for performance |

#### MIGRATE (Clean SwiftUI Replacements Available)

| # | Component | File(s) | Current Pattern | SwiftUI Replacement | Effort |
|---|---|---|---|---|---|
| 7.1 | Middle-click tab close | `EditorTabBar.swift:114-133` | `MiddleClickView` NSViewRepresentable + `MiddleClickNSView` | SwiftUI `.overlay()` with `onTapGesture` or `.onLongPressGesture` — or keep; middle-click is genuinely hard in SwiftUI | Low |
| 7.2 | Focus forwarding | `FocusForwardingContainerView.swift` | `NSView` subclass intercepting `mouseDown` | `@FocusState` + `.onTapGesture` in SwiftUI | Low |
| 7.3 | Window reference capture | `ContentView.swift:543-561` (`WindowResolver`) | `NSViewRepresentable` to get `NSWindow` | `@Environment(\.window)` or access via `NSApplication.shared.keyWindow` in `onAppear` | Low |
| 7.4 | Cmd+W event monitor | `compassApp.swift:471-476` | `NSEvent.addLocalMonitorForEvents` | SwiftUI `.onCommand()` or `.keyboardShortcut("w", modifiers: .command)` (already exists in `commands` block, making this monitor redundant) | Low |
| 7.5 | NSAlert for rename | `compassApp.swift:357-375` | `NSAlert.runModal()` | SwiftUI `.alert()` modifier with `TextField` | Medium |
| 7.6 | Theme detection (NSApp.effectiveAppearance) | `UIStateManager.swift:330-336` | `NSApp.effectiveAppearance.bestMatch(from:)` | `@Environment(\.colorScheme)` in SwiftUI views — system theme is already propagated | Low |
| 7.7 | Window chrome setup | `ContentView.swift:506-541` (`WindowSetupView`) | Direct `NSWindow` mutation: `styleMask`, `backgroundColor`, `setFrame` | SwiftUI scene modifiers: `.windowResizability()`, `.defaultPosition()`, `.windowStyle()` | Medium |
| 7.8 | `NSCursor` on dividers | `ContentView.swift:418-468` | `NSCursor.resizeLeftRight.push()`/`.pop()` | SwiftUI `.onHover {}` + `NSCursor` (this is already the standard pattern; keep as-is) | **Skip** |
| 7.9 | `Color(nsColor: .xxx)` bridging | ~20 components | Direct `NSColor` → `Color` constructor | Already handled by `AppConstantsColor` tokens in Phase 1; migrate remaining inline usages | Low |

### Phase 7 Implementation Plan

#### 7.1 — Middle-Click Tab Close (Evaluate)
**Current**: `MiddleClickView` wraps an NSView that captures `otherMouseDown` (middle-click).  
**Options**:
- **Option A** (Keep): Add a comment explaining why AppKit is needed. The middle-click event (`otherMouseDown`) has no SwiftUI equivalent.
- **Option B** (Replace): Use `contextMenu` on tabs as a secondary close affordance, and accept that middle-click is platform-only.

**Recommendation**: Keep as-is. Middle-click has no SwiftUI gesture equivalent. Add documentation comment.

**Files**: `Components/EditorTabBar.swift:114-133`

#### 7.2 — Focus Forwarding → SwiftUI @FocusState
**Current**: `FocusForwardingContainerView` is an `NSView` subclass that calls `onFocusRequested` on mouseDown.
**Replacement**:
```swift
// Instead of wrapping in FocusForwardingContainerView:
.onTapGesture { focusedPane = .primary }
```
**Files**: 
- `Components/FocusForwardingContainerView.swift` — Delete
- `Components/EditorPaneView.swift` — Replace wrapping with `.onTapGesture`

#### 7.3 — WindowResolver → Environment Key
**Current**: `WindowResolver` is an `NSViewRepresentable` that captures the window ref.
**Replacement**:
```swift
struct WindowAccessorKey: EnvironmentKey {
    static let defaultValue: NSWindow? = nil
}
extension EnvironmentValues {
    var nsWindow: NSWindow? { self[WindowAccessorKey.self] }
}
```
Then set it once in `AppRootView` or the root Window scene.

**Files**:
- **New**: `Services/WindowAccessor.swift`
- `ContentView.swift` — Replace `WindowResolver` with environment access
- `ContentView.swift:506-541` — `WindowSetupView` can read `@Environment(\.nsWindow)` instead

#### 7.4 — Cmd+W Event Monitor → Redundant (already handled by keyboard shortcut)
**Current**: `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` captures Cmd+W to close tabs.
**Problem**: `compassApp.swift:245` already has `.keyboardShortcut("w", modifiers: [.command])` for `editor.close_tab`. The event monitor duplicates this and intercepts the event before SwiftUI's command system processes it.
**Replacement**: Remove the event monitor. The `.commands {}` block already handles Cmd+W for close tab.

**Files**:
- `compassApp.swift:471-483` — Remove event monitor logic in `AppRootView.onAppear`/`.onDisappear`

#### 7.5 — NSAlert → SwiftUI .alert()
**Current**: `NSAlert` with `runModal()` for rename dialog (blocking, AppKit-modal).
**Replacement**:
```swift
@State private var renameText: String = ""
@State private var isRenamePresented = false

.alert("Rename", isPresented: $isRenamePresented) {
    TextField("New name", text: $renameText)
    Button("Rename") { doRename() }
    Button("Cancel", role: .cancel) { }
}
```
**Files**:
- `compassApp.swift:357-375` — Replace NSAlert rename with `.alert()` modifier
- `compassApp.swift` — Add `@State` for rename flow
- `AppRootView` — Add `.alert()` modifier

#### 7.6 — Theme Detection → @Environment(\.colorScheme)
**Current**: Manual `NSApp.effectiveAppearance.bestMatch(from:)` to detect dark/light.
**Replacement**: SwiftUI already propagates `@Environment(\.colorScheme)` to all views. The `isDarkMode` published property in `UIStateManager` can be derived from the environment instead of polling `NSApp`.
```swift
@Environment(\.colorScheme) var colorScheme
// Use colorScheme directly instead of uiState.isDarkMode
```
**Files**:
- `Services/UIStateManager.swift` — Remove `isDarkMode` and `updateTheme()` NSApp polling; views use `@Environment(\.colorScheme)`

#### 7.7 — Window Chrome → Scene Modifiers
**Current**: `WindowSetupView` mutates `NSWindow` directly: `styleMask`, `backgroundColor`, `minSize`, `setFrame`.
**Replacement**: Use SwiftUI scene modifiers on the `Window` scene:
```swift
Window("compass", id: "main") { ... }
    .windowStyle(.hiddenTitleBar)        // Already done
    .windowToolbarStyle(.unifiedCompact) // Already done
    .windowResizability(.contentSize)    // Instead of manual frame
    .defaultPosition(.center)
```
Remaining window setup (title sync) can use the `WindowAccessor` environment key.

**Files**:
- `ContentView.swift:506-541` — Remove `WindowSetupView`; move logic to scene modifiers + `WindowAccessor`

#### 7.8 — NSCursor on Dividers (Skip)
Already follows the standard SwiftUI pattern (NSCursor is pushed/popped inside `.onHover`). No better SwiftUI equivalent. **Keep as-is**.

#### 7.9 — NSColor → Color → AppConstantsColor Migration
**Current**: 20+ files use `Color(nsColor: .xxx)` or `NSColor.xxx` directly.
**Replacement**: Use `AppConstants.Color` tokens where defined. For one-off system colors not in the token set, add them to `AppConstantsColor`.

**Migration targets**:
| NSColor Used | Replace With | Files Affected |
|---|---|---|
| `.windowBackgroundColor` | `.Color.surfaceBackground` | `SettingsView.swift:76`, `compassApp.swift:505` |
| `.controlBackgroundColor` | `.Color.surfaceSidebar` or `.surfaceCard` | `ChatInputView.swift:47`, `AIChatPanel.swift:116,121`, `EditorTabBar.swift:90,97`, `ModelSuggestionList.swift:37`, `NewProjectDialog.swift:45`, `ReasoningOutcomeMessageView.swift:37`, `InlineAIPopoverView.swift:108` |
| `.textBackgroundColor` | `.Color.terminalBackground` | `LogsPanelView.swift:44,61`, `ToolExecutionMessageView.swift:345`, `MinimapView.swift:12`, `EditorPaneView.swift:63,111`, `TextViewRepresentable.swift:42`, `MarkdownView.swift:250` |
| `.secondarySystemFill` | `.Color.surfaceCard` | `MessageListView.swift:32`, `MessageContentCoordinator.swift:97` |
| `.labelColor` | `.Color.textPrimary` | `TextViewRepresentable.swift:43`, `LineNumberRulerView.swift:12,153` |
| `.secondaryLabelColor` | `.Color.textSecondary` | `LineNumberRulerView.swift:12,153` |
| `.placeholderTextColor` | `.Color.textTertiary` | `ChatInputView.swift:66`, `CodeEditorTextView.swift:128` |
| `.separatorColor` | `.Color.separatorDefault` or `.separatorSubtle` | Multiple files |

**Files**: ~20 component files

### Phase 7 — Implementation Order

```
Phase 7.2 (FocusForwarding) ─── Small, safe, no deps
        │
Phase 7.4 (Cmd+W monitor) ──── No deps, pure deletion
        │
Phase 7.6 (Theme detection) ─── Depends: views use @Environment instead of isDarkMode
        │
Phase 7.9 (NSColor→Color) ───── Depends: AppConstantsColor from Phase 1
        │
Phase 7.3 (WindowAccessor) ──── No deps (new file + refactor)
        │
Phase 7.5 (NSAlert→.alert) ──── No deps
        │
Phase 7.7 (Window chrome) ───── Depends: 7.3 (WindowAccessor)
        │
Phase 7.1 (Middle-click) ────── Low priority, evaluate-only
```

### Risk Assessment

| Migration | Risk | Mitigation |
|---|---|---|
| 7.2 FocusForwarding → onTapGesture | Low | `.onTapGesture` preserves mouse interaction; verify focus still works |
| 7.4 Remove Cmd+W monitor | Low | Monitor is redundant with SwiftUI keyboard shortcut; verify Cmd+W still closes tabs |
| 7.6 Theme detection → @Environment | Low | `@Environment(\.colorScheme)` is the canonical SwiftUI approach |
| 7.9 NSColor → Color tokens | Low | Token values already use same NSColor sources; pure rename |
| 7.3 WindowAccessor | Medium | Must ensure window reference is available at right time; test on first launch |
| 7.5 NSAlert → .alert | Medium | SwiftUI `.alert()` is modal but non-blocking; verify rename flow works |
| 7.7 Window chrome → scene modifiers | Medium | Window sizing may change; test on multi-monitor |
| 7.1 Middle-click | Low | If kept, no risk; if replaced, gesture API may differ |

### Files Summary — Phase 7

**Delete (3)**: `FocusForwardingContainerView.swift`, `WindowResolver` block in ContentView, redundant event monitor code

**Modify (~25)**:
- Low touch: `EditorTabBar.swift` (documentation only), `UIStateManager.swift`, `compassApp.swift`
- Medium touch: `ContentView.swift`, `EditorPaneView.swift`, `SettingsView.swift`
- Token migration: `ChatInputView.swift`, `AIChatPanel.swift`, `EditorTabBar.swift`, `ModelSuggestionList.swift`, `NewProjectDialog.swift`, `ReasoningOutcomeMessageView.swift`, `InlineAIPopoverView.swift`, `LogsPanelView.swift`, `ToolExecutionMessageView.swift`, `MinimapView.swift`, `EditorPaneView.swift`, `TextViewRepresentable.swift`, `MarkdownView.swift`, `MessageListView.swift`, `MessageContentCoordinator.swift`, `LineNumberRulerView.swift`, `CodeEditorTextView.swift`

**Create (1)**: `Services/WindowAccessor.swift`

## Build Verification

After each phase:
1. `xcodebuild -scheme compass build` — Must compile
2. Visual inspection of affected views in both light and dark mode
3. Check accessibility identifiers are preserved
