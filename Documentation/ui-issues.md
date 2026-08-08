# UI Layer Comprehensive Audit — 2026-08-08

## Executive Summary

The Compass UI layer contains **100+ specific issues** across 74 Component files. While an 8pt spacing scale and liquid glass API are partially implemented, adoption is uneven and the first-launch visual impression suffers from several class of issues that a client sees before pressing anything:

1. **Chrome/separator overreach** — panel dividers, text editor internal lines, and separator bars extend beyond their logical content areas into the system title bar.
2. **Missing visible separation** — the line-number gutter has no right-edge divider, so gutter and source visually blend at first glance.
3. **Adjacent-control inconsistency** — the mode selector and model selector sit next to each other in the same toolbar but use two different dropdown mechanisms (Menu vs. Button+popover) with subtly different chevron weights.
4. **Partial liquid-glass adoption** — only ~33% of surfaces route through the unified `nativeGlassBackground(_:)` helper. The rest either use raw `.glassEffect(.regular, in:)` (inconsistent borders/corners) or no glass at all (flat color fills).
5. **44+ magic spacing/size literals** — dots, frames, paddings, and corner radii are hardcoded independently in every file, rather than pulling from `AppConstants.*` design tokens.
6. **Settings has 3 visual idioms** — General (cards), AI (bare sections), and Agent (native `Form .grouped`) look like three different apps.
7. **5 different divider renderings** — `IDESectionDivider`, `Divider()`, `Rectangle().fill(...)`, panel dividers, and tab-bar rectangles all use different thickness/opacity values despite being the same semantic element.

This document records **every verified call site** before fixes begin, so regressions can be diffed against a known baseline. No code has been changed; this is read-only findings.

## Review Scope and Method

- Audited 74 production Swift UI files (all files matching `Compass/Components/*.swift`).
- Reviewed root layout composition: `ContentView.swift` → `mainLayout` → `workspaceLayout` → `PanelDivider` overlays, plus title-bar integration.
- Traced adoption of `nativeGlassBackground(_:)` / `NativeGlassSurface` helpers against raw `.glassEffect` call sites.
- Compared every hardcoded `.padding(N)`, `.frame(width/height: N)`, `.cornerRadius(N)` literal against `AppConstantsLayout.swift`, `AppConstantsColor.swift`, `AppConstantsEditor.swift`, `AppConstantsOverlay.swift`, `AppConstantsSettings.swift` tokens.
- Validated mode-vs-model selectors against DESIGN_STANDARDS.md §6 ("Adjacent controls of the same role share one idiom").
- Validated Settings tabs §2 ("Card visuals are shared, not per-tab").

---

## Findings

### P0 — First-Impression (Client Sees Before Pressing Anything)

These defects are visible within 1 second of launch on the default workspace layout.

---

#### P0-1. Column Panel Separators Overreach Into The System Title Bar

**Severity:** P0 — chrome polish issue, visually breaks the window.
**Impact:** Users perceive the app as "not properly integrated with macOS" because interior panel lines cross the transparent title-bar region.

**Evidence:**

The root `workspaceLayout` in `ContentView` composes a plain `HStack(spacing: 0)` with three `PanelDivider` components rendered as overlays. Each divider's `Rectangle()` fills from the very top of the HStack (y=0 of the window) to the very bottom. No safe-area or header-height clipping is applied.

Since `mainLayout` is a `VStack(spacing: 0)` with zero padding before the content area, and `WindowSetupView` is a zero-size `Color.clear` frame, there is no structural element that prevents the divider from painting through the title-bar overlap region. The liquid-glass root is at the ZStack level with `.cornerRadius(0)`, so the separators are drawn **on top of** the glass and extend unbroken into the window toolbar.

- Divider overlay (no inset): [ContentView.swift:482-494](file:///Users/jack/Projects/osx/osx-ide/Compass/ContentView.swift#L482-L494)
  - `PanelDivider.overlay(Rectangle())` has no alignment guides or safe-area padding.
- Main layout VStack (0 spacing): [ContentView.swift:80-92](file:///Users/jack/Projects/osx/osx-ide/Compass/ContentView.swift#L80-L92)
- WindowSetupView is `frame(width: 0, height: 0)` at the bottom of the layout, not the top: [ContentView.swift:500-529](file:///Users/jack/Projects/osx/osx-ide/Compass/ContentView.swift#L500-L529)
- Root liquid glass, cornerRadius 0 (covers entire window including toolbar overlap): [ContentView.swift:47](file:///Users/jack/Projects/osx/osx-ide/Compass/ContentView.swift#L47-L47)

**Recommendation:**
1. Add a top-inset equal to `AppConstants.Layout.headerHeight` to each `PanelDivider.overlay`'s Rectangle. Example:
   ```swift
   Rectangle()
       .fill(AppConstants.Color.panelDivider ?? .separatorDefault)
       .padding(.top, AppConstants.Layout.headerHeight)
   ```
2. Consider additionally insetting by `.padding(.bottom, AppConstants.Layout.statusBarHeight)` so separators stop at the status bar top.

---

#### P0-2. No Visible Divider Between Line-Number Gutter and Source Code

**Severity:** P0 — structural clarity.
**Impact:** At a glance, a user cannot tell where line numbers end and code begins. The gutter visually bleeds into the code area because both surfaces share the same background with no stroke separator.

**Evidence:**

`ModernLineNumberRulerView` paints its background with `NSColor.clear.cgColor`. Its `drawHashMarksAndLabels` call site fills the ruler background rect with `NSColor.clear.setFill()`, then paints numbers right-aligned to `ruleThickness - 6 - labelSize.width`. There is **no vertical stroke** drawn at the gutter→editor seam (`x = ruleThickness - 1 / y = 0 ... height`).

- Clear background layer: [LineNumberRulerView.swift:19](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/LineNumberRulerView.swift#L19-L19)
- Hash marks draw pass (no separator stroke): [LineNumberRulerView.swift:75-103](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/LineNumberRulerView.swift#L75-L103)
- Number label x-offset (right edge minus 6pt minus label width, nothing at right edge): [LineNumberRulerView.swift:176](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/LineNumberRulerView.swift#L176-L176)
- Compare to tab bar, which correctly renders a Rectangle separator: [EditorTabBar.swift:51-53](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/EditorTabBar.swift#L51-L53)

**Related, same P0:** The editor pane's Minimap `Divider()` overreaches the tab header by `headerHeight`.

`EditorPaneView.editorContent` composes CodeEditorView + `Divider()` + MinimapView inside an HStack. This `Divider()` is a native SwiftUI 0.5pt hairline with no insets, so it paints from the top of the HStack (including the tab bar region) to the bottom. Since EditorTabBar is **sibling** above this HStack (not parent/inside), the Minimap divider **bleeds up through** the header height (~30pt) and visually overlaps the tab bar separator area.

- EditorPane composition: [EditorPaneView.swift:99-106](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/EditorPaneView.swift#L99-L106)
- Minimap frame sizing (no relation to tab bar height): [MinimapView.swift:57-60](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/MinimapView.swift#L57-L60)

**Recommendation:**
1. Inside `ModernLineNumberRulerView.drawHashMarksAndLabels`, add a 1pt vertical stroke at the right edge:
   ```swift
   NSBezierPath.stroke(
       NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height),
       using: AppConstants.Color.gutterSeparator ?? .separatorColor
   )
   ```
2. Wrap the Minimap's divider in a container that applies `.padding(.top, AppConstants.Layout.headerHeight)` OR move the `Divider` into the outer `editorRoot` VStack **below** the TabBar (so it shares the same vertical span as the CodeEditor region only, not the entire pane).
3. Add new token `AppConstants.Layout.gutterSeparatorWidth: CGFloat = 1` and color `AppConstants.Color.gutterSeparator` to prevent future literal drift.

---

#### P0-3. Mode Selector vs. Model Selector — Mismatched Mechanisms and Chevron Weights

**Severity:** P0 — DESIGN_STANDARDS.md §6 explicit violation.
**Impact:** Two dropdowns sit next to each other in the same header, visually adjacent. They behave differently on-click (one drops a native Menu, the other pops up a popover with an arrow), they show different pressed-state chrome, and their chevrons use different font weights. Users perceive the UI as "thrown together" instead of a single design system.

**Evidence:**

| Concern | Mode Selector (left) | Model Selector (right) |
|---|---|---|
| Component | Native `Menu { ... } label: { IDECapsuleDropdownLabel }` | Custom `Button` + `.popover(isPresented:)` |
| Chrome | `.menuStyle(.borderlessButton)` + `.menuIndicator(.hidden)` with explicit chevron inside label | No menu chrome; plain SwiftUI Button; popover renders with upward arrow |
| Pressed-state | System Menu highlight | Button's implicit pressed alpha |
| Chevron source | `Image(systemName: "chevron.down")` inside `IDECapsuleDropdownLabel` | Same label reused (good) — BUT reasoning sub-menu uses a 2nd style |
| Chevron weight (outer) | Bare `.system(size: AppConstants.Layout.controlChevronSize)` — no explicit weight | Same (good) |
| Chevron weight (inner footer) | N/A | Same controlChevronSize but **NO weight** while peers below all specify `.caption2.weight(.medium)` |

- Mode menu: [AIChatPanel.swift:225-237](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L225-L237)
- Model popover: [AIChatPanel.swift:241-253](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L241-L253)
- Model popover reasoning sub-menu (Menu + `.borderedButton` + bare chevron): [AIChatPanel.swift:379-404](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L379-L404)
  - Chevron at line [399](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L399-L399) — no `.weight(.medium)`
- Peer chevrons (all explicitly `.caption2.weight(.medium)` for consistency):
  - Tool execution expander: [ToolExecutionMessageView.swift:198](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ToolExecutionMessageView.swift#L198-L198)
  - Reasoning bubble expander: [ReasoningMessageView.swift:47](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ReasoningMessageView.swift#L47-L47)

**Additionally — double-indicator risk:** The Mode menu sets `.menuIndicator(.hidden)` *and* the label already has an explicit chevron drawn inside `IDECapsuleDropdownLabel`. If `.menuIndicator(.hidden)` silently fails on any macOS minor version (known AppKit quirk: some MenuStyle variants ignore `.menuIndicator(.hidden)` on specific control sizes), the mode selector will render **two chevrons**. The model selector has no risk here because it uses `Button` + popover; this asymmetry is itself an inconsistency.

- `IDECapsuleDropdownLabel` always draws the chevron: [NativeIDEComponents.swift:91](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/NativeIDEComponents.swift#L91-L91)
- Mode menu tries to suppress built-in indicator: [AIChatPanel.swift:237](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L237-L237)

**Recommendation:**
1. Pick one idiom. For both controls, use `Menu` with `.menuStyle(.borderlessButton)` and `.menuIndicator(.hidden)` — this guarantees the pressed-state, open-direction, and click-outside-dismiss behavior are identical. Move the model list contents into the Menu's content block instead of a separate popover.
2. Add `.caption2.weight(.medium)` to the reasoning sub-menu chevron at [AIChatPanel.swift:399](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L399-L399).
3. Add a unit test or SwiftUI preview that captures both controls side-by-side with baseline image diffing.

---

#### P0-4. Liquid Glass Only Applied To ~33% Of Surfaces; 2 Coexisting Styles

**Severity:** P0 — design-system non-compliance (DESIGN_STANDARDS §4 and §11: "Glass surfaces use nativeGlassBackground(_:)/NativeGlassSurface").
**Impact:** Surfaces that should have identical material look slightly different — different tinting, different default corner radii, missing unified border stroke. The eye picks up subtle material mismatches even when the user can't name the cause.

**Evidence — raw `.glassEffect(.regular, in:)` NOT going through helper (8 call sites):**

| File | Line | Surface |
|---|---|---|
| [ChatInputView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ChatInputView.swift#L49-L49) | 49 | Chat text field background |
| [ChatInputView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ChatInputView.swift#L71-L71) | 71 | Stop button circle |
| [ChatInputView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ChatInputView.swift#L86-L86) | 86 | Send button circle |
| [AIChatPanel.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L114-L114) | 114 | Active conversation tab pill |
| [ToolExecutionMessageView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ToolExecutionMessageView.swift#L103-L103) | 103 | Tool execution bubble |
| [EditorTabBar.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/EditorTabBar.swift#L95-L95) | 95 | Active editor tab pill |
| [SettingsStatusPill.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/SettingsStatusPill.swift#L18-L18) | 18 | Settings connection status pill |

**Major panels with NO glass at all (flat fills or transparent defaults):**

| Surface | File | Current Treatment |
|---|---|---|
| File Explorer sidebar | [FileExplorerView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/FileExplorerView.swift) | No background modifier; falls back to window background. Sidebars on macOS 26 should read as `.sidebar` material. |
| Settings window background | [SettingsView.swift:85-89](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/SettingsView.swift#L85-L89) | `SettingsBackgroundView` fills `AppConstants.Color.surfaceBackground` solid color. Should be `.nativeGlassBackground(.windowBackground, cornerRadius: 0)`. |
| Status bar strip | [IndexStatusBarView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/IndexStatusBarView.swift) | No glass, flat strip. Reads as a different material than the panel area above it. |
| Chat message list inner scroll | No single glass wrapper around MessageListView (transparent on panel background). Markdown message bubbles use flat card fills. This is defensible design-wise but inconsistent with the rest of the surfaces. |

**Chat input field has double-material bug (wastes GPU):**
`ChatInputView.swift:46-50` paints an OPAQUE solid `surfaceCard` fill UNDER the translucent liquid glass material:

```swift
inputShape.fill(AppConstants.Color.surfaceCard)
    .glassEffect(.regular, in: inputShape)
```

Glass by definition shows what is beneath. Putting solid color under negates the glass, produces a darker/flatter result than every other glass surface in the app, and pays the composite cost for no benefit. Every other `nativeGlassBackground(.panel)` call does **not** do this.

- [ChatInputView.swift:46-50](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ChatInputView.swift#L46-L50)

**Recommendation:**
1. Replace all 8 raw `.glassEffect(.regular, in:)` calls with `nativeGlassBackground(.panel, cornerRadius: ..., showBorder: ...)`, matching existing helper conventions.
2. Remove the `inputShape.fill(AppConstants.Color.surfaceCard)` underlayer from ChatInputView — glass alone is the background.
3. Apply `.nativeGlassBackground(.sidebar, cornerRadius: 0)` to FileExplorer's outer container.
4. Apply `.nativeGlassBackground(.windowBackground, cornerRadius: 0, showBorder: false)` to Settings window root, replacing flat solid-color fill.
5. Apply matching glass to status-bar strip so it's the same material as what's above.

---

### P1 — Spacing / Padding / Alignment Violations (44+ Magic Literals)

DESIGN_STANDARDS.md §2 mandates 8pt spacing scale: `XXS=2, XS=4, Sm=8, Md=12, Lg=16, XL=24, XXL=32, XXXL=48`. Any value NOT in this set (and not explicitly a documented AppConstants token) is a violation.

---

#### P1-1. Four Instances of "Status / Indicator Dots" — 3 Different Sizes (7pt, 6pt)

Should all read from a single `AppConstants.Layout.statusDotSize` token.

| File | Line | Current Literal | Semantic |
|---|---|---|---|
| [EditorTabBar.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/EditorTabBar.swift#L85-L85) | 85 | `6 x 6` (.frame(width: 6, height: 6)) | Dirty indicator on tab |
| [SettingsStatusPill.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/SettingsStatusPill.swift#L10-L10) | 10 | `6 x 6` | Connection health dot |
| [IndexStatusBarView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/IndexStatusBarView.swift#L199-L199) | 199 | `6 x 6` | Status-state dot |
| [MessageListView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/MessageListView.swift#L21-L21) | 21 | `7 x 7` (off by 1pt from peers) | Typing indicator "typing…" dot |

**Recommendation:**
1. Add `AppConstants.Layout.statusDotSize: CGFloat = 6` (align 3 correct ones)
2. Add `AppConstants.Layout.typingIndicatorDotSize: CGFloat = 7` only if design team specifically wants the typing dot larger; otherwise unify to 6.
3. Replace all 4 literals.

---

#### P1-2. Compact Icon Frames — 14pt Token Exists But 8 Literals Still Use 16pt (Unrelated Value)

`AppConstants.Layout.compactIconSize = 14` exists and is the documented token. Multiple call sites ignore it.

| File | Line | Literal | Should Be |
|---|---|---|---|
| [AIChatPanel.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L512-L512) | 512 | `.frame(width: 16, height: 16)` | `compactIconSize` (14) or a new `regularIconSize = 16` token |
| [ToolExecutionMessageView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ToolExecutionMessageView.swift#L214-L214) | 214 | `.frame(width: 16, height: 16)` | Same |
| [ToolExecutionMessageView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ToolExecutionMessageView.swift#L358-L358) | 358 | `.frame(width: 16, height: 16)` | Same |
| [ToolExecutionMessageView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ToolExecutionMessageView.swift#L373-L373) | 373 | `.frame(width: 16, height: 16)` | Same |
| [EditorTabBar.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/EditorTabBar.swift#L141-L141) | 141 | `.frame(width: 14, height: 14)` (correct value, but as LITERAL) | `AppConstants.Layout.compactIconSize` |

**Recommendation:**
1. Add `AppConstants.Layout.regularIconSize: CGFloat = 16` alongside the existing `compactIconSize = 14`.
2. Replace all 5 icon-frame literals with either token.

---

#### P1-3. Card / Pill Inner Padding — 10pt Is Not In The 8pt Scale

All instances below use `padding(10)` or equivalent. The 8pt scale has no `10`; nearest are `Sm=8` or `Md=12`.

| Surface | File + Line | Literal |
|---|---|---|
| Settings status pill horizontal + vertical | [SettingsStatusPill.swift:16-17](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/SettingsStatusPill.swift#L16-L17) | h=10, v=6 (v is fine = spacingXxs*3, but 10 is odd) |
| Model suggestion row padding | [ModelSuggestionList.swift:29-30](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ModelSuggestionList.swift#L29-L30) | h=10, v=8 (v fine as Sm, h=10 off) |
| Model suggestion container outer | [ModelSuggestionList.swift:40](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ModelSuggestionList.swift#L40-L40) | `.padding(10)` |
| NewProjectDialog VStack spacing | [NewProjectDialog.swift:30](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/NewProjectDialog.swift#L30-L30) | `spacing: 20` (20 not in scale) |
| Chat typing bubble vertical | [MessageListView.swift:26](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/MessageListView.swift#L26-L26) | v=9 (not in scale; h=12=Md correct) |

**Additionally: Correct-value-but-as-literals (not a value bug, is a source-of-truth bug):**
- LogsPanel inner padding(8): [LogsPanelView.swift:42](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/LogsPanelView.swift#L42-L42) → should be `.spacingSm`
- OverlayHeaderView spacing(8): [OverlayHeaderView.swift:13](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/OverlayHeaderView.swift#L13-L13) → `.spacingSm`
- OverlayScaffold spacing(12): [OverlayScaffold.swift:20](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/OverlayScaffold.swift#L20-L20) → `.spacingMd`
- SettingsView outer padding(24): [SettingsView.swift:79](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/SettingsView.swift#L79-L79) → `.spacingXl`
- SettingsRow vertical padding(4): [SettingsRow.swift:41](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/SettingsRow.swift#L41-L41) → `.spacingXs`
- SettingsRow title/subtitle spacing(2): [SettingsRow.swift internal] → `.spacingXxs`
- SettingsCard title/subtitle spacing(4): [SettingsComponents.swift:23](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/SettingsComponents.swift#L23-L23) → `.spacingXs`

**Recommendation:**
1. Decide: for `10pt` (appears 3x), either upgrade to `Md=12` or downgrade to `Sm=8`. Do NOT use 10.
2. For `20` (NewProjectDialog): choose `Xl=24` or `Lg=16`.
3. For typing bubble `9`: choose `Sm=8` or `Md=12`.
4. Replace 8 correct-but-literal spacings with their named AppConstants tokens so a design-system update propagates automatically.

---

#### P1-4. 22 Explicit `.frame(width: N)` Hardcoded Widths In Settings / Popovers

No control should have an independent literal width. If design decides "provider picker is 250pt" today, 14 call sites need touching.

**Hardcoded widths in Settings family:**

| File | Line | Width (pt) | Purpose |
|---|---|---|---|
| [GeneralSettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/GeneralSettingsTab.swift#L191-L191) | 191 | 160 | Stepper (suggestion length) |
| [IndexStatusBarView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/IndexStatusBarView.swift#L315-L315) | 315 | 300×360 | Diagnostics popover frame |
| [IndexStatusBarView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/IndexStatusBarView.swift#L367-L367) | 367 | 240 | File type Picker |
| [IndexStatusBarView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/IndexStatusBarView.swift#L402-L402) | 402 | 80 | Status pill fixed width |
| [IndexStatusBarView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/IndexStatusBarView.swift#L454-L454) | 454 | 260 | Balance/cost popover |
| [IndexStatusBarView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/IndexStatusBarView.swift#L469-L469) | 469 | 80 | Spend/context statuses width |
| [FileExplorerView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/FileExplorerView.swift#L130-L130) | 130 | 300 | New file sheet width |
| [FileExplorerView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/FileExplorerView.swift#L148-L148) | 148 | 300 | New folder sheet width |
| [InlineAIPopoverView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/InlineAIPopoverView.swift#L151-L151) | 151 | 320 | Inline QA popover |
| [NewProjectDialog.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/NewProjectDialog.swift#L97-L97) | 97 | 400×250 | New project modal |
| [LocalModelSettingsView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/LocalModelSettingsView.swift#L95-L95) | 95 | 420 | Progress bar width |
| [LocalModelSettingsView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/LocalModelSettingsView.swift#L107-L107) | 107 | 420 | Download progress |
| [AISettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AISettingsTab.swift#L175-L175) | 175 | 240 | Provider picker |
| [AISettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AISettingsTab.swift#L213-L213) | 213 | 240 | Model Picker |
| [AISettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AISettingsTab.swift#L247-L247) | 247 | 260 | Key status pill |
| [AISettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AISettingsTab.swift#L268-L268) | 268 | 120 | Validate Key button |
| [AISettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AISettingsTab.swift#L302-L302) | 302 | 260 | AI tab popovers (x3) |
| [AISettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AISettingsTab.swift#L394-L394) | 394 | 340 | System prompt |
| [AISettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AISettingsTab.swift#L407-L407) | 407 | 220 | Tool prompt mode |

**Recommendation:** Create tokens (in `AppConstantsSettings` / `AppConstantsOverlay`) for each semantic category, then replace all literals:

| Proposed Token | Value (pt) |
|---|---|
| `popoverWidthCompact: 240` | 240 (file type, pickers) |
| `popoverWidthDefault: 300` | 300 (new file/folder, diagnostics) |
| `popoverWidthWide: 320` | 320 (inline QA, closed convos) |
| `popoverWidthExtraWide: 340` | 340 (system prompt) |
| `settingsStepperWidth: 160` | 160 |
| `settingsKeyStatusWidth: 260` | 260 |
| `settingsValidateBtnWidth: 120` | 120 |
| `settingsPromptModeWidth: 220` | 220 |
| `modalWidthNewProject: 400`, `modalHeightNewProject: 250` | 400×250 |
| `progressBarWidth: 420` | 420 |

---

### P2 — Structural / Consistency Issues

#### P2-1. Settings Rendered in 3 Different Visual Idioms

Three tabs, three completely different layout systems. Clicking General → AI → Agent produces visually disjoint screens.

| Tab | File | Idiom |
|---|---|---|
| **General** | [GeneralSettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/GeneralSettingsTab.swift) | `ScrollView` → `VStack` → N× `SettingsCard` wrapper. Each card contains `SettingsRow`s with icon + title/subtitle on left, control on right. Consistent card chrome, padding, corner radius. **Correct baseline.** |
| **AI** | [AISettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AISettingsTab.swift) | NO outer `SettingsCard` wrappers for `ProviderSelectionSection`, `ProviderConnectionSection`, `ModelSelectionSection`, `SystemPromptSection`, or `ReasoningSection`. Each Section component rolls its own padding, header, and chrome independently. Only the "Local Models" subsection wraps in `SettingsCard`. The AI tab therefore reads as older/unfinished compared to General. |
| **Agent** | [AgentSettingsTab.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AgentSettingsTab.swift) | Uses native SwiftUI `Form { Section(header: ...) { ... } }` with `.formStyle(.grouped)`. This is a **completely different rendering engine**: native group-style rounded rectangles, section title typography, section header padding, cell heights, and corner radii all differ from `SettingsCard`. The Agent tab is visually the most inconsistent panel in the app. |

**Recommendation:**
1. Wrap every AI Settings section in a `SettingsCard(title:icon:)` header (matching General tab style exactly). Same spacing tokens, same card radius/padding.
2. Replace AgentSettingsTab's `Form { }` + `.formStyle(.grouped)` with same `ScrollView` → `VStack` → `SettingsCard` → `SettingsRow` pattern.
3. Once all three tabs share one idiom, promote the pattern into a reusable `SettingsTabContentView { VStack { SettingsCard(...) ... } }` helper.

---

#### P2-2. Five Different Divider Idioms (No Single Source Of Truth)

The project provides `IDESectionDivider` as a standard component. It is used in exactly **2 places** in the entire codebase. Every other divider location rolls its own rendering.

- Standard component definition: [NativeIDEComponents.swift:74-80](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/NativeIDEComponents.swift#L74-L80)
  - A 0.5pt line of `.separatorColor` with 2pt vertical padding.
- Used at:
  - AIChatPanel tab header bottom: [AIChatPanel.swift:179](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L179-L179)
  - WorkspacePanelHeader bottom: [NativeIDEComponents.swift:62-64](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/NativeIDEComponents.swift#L62-L64)

**The 4 other divider idioms coexisting:**

1. **EditorTabBar top/bottom separators** — standalone `Rectangle().fill(AppConstants.Color.separatorDefault)`. Uses a DIFFERENT color source (`.separatorDefault` Color, not `.separatorColor` NSColor) than `IDESectionDivider`.
   - [EditorTabBar.swift:51-53](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/EditorTabBar.swift#L51-L53)

2. **ContentView bottomPanelHeader separator** — same standalone Rectangle pattern, different location:
   - [ContentView.swift:301-305](file:///Users/jack/Projects/osx/osx-ide/Compass/ContentView.swift#L301-L305)

3. **SettingsCard internal divider** — `Divider().opacity(0.4)` (3rd opacity value, 3rd component type).
   - [SettingsComponents.swift:32-33](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/SettingsComponents.swift#L32-L33)

4. **Popovers (ModelPicker, ClosedConversations)** — bare `Divider()` with no opacity tuning (default system opacity, 4th variant).
   - [AIChatPanel.swift:333](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L333-L333)
   - [AIChatPanel.swift:359](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L359-L359)
   - [AIChatPanel.swift:435](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/AIChatPanel.swift#L435-L435)

5. **PanelDivider (column splitters)** — `Color.panelDivider` or `.separatorSubtle` (5th color choice).
   - [ContentView.swift:486-493](file:///Users/jack/Projects/osx/osx-ide/Compass/ContentView.swift#L486-L493)

**Impact:** Clients perceive "some lines are thicker than others" for no semantic reason — section dividers vary 0.40 opacity → 0.5pt → 1pt → system default, across the app.

**Recommendation:**
1. Add two tokens (each produces exactly ONE rendering):
   - `IDESectionDivider` — semantic content boundary (between rows in a list, card footer).
   - `IDEPanelDivider` — inter-panel splitter (column dividers, minimap divider; thicker 1pt, separate color, clipped below headerHeight).
2. Deprecate bare `Divider()` and bare `Rectangle().fill(.separator...)` in UI code. Lint against them.

---

#### P2-3. `cardCornerRadius: 16` Duplicates `cornerXL: 16` (One Off-Spec Literal, One Unlinked Token)

DESIGN_STANDARDS §3 says corner radii must be in the scale: `XXS=2, XS=4, Sm=6, Md=8, Lg=12, Xl=16`. `AppConstants.Layout.cornerXL = 16` EXISTS in the scale.

`AppConstants.Settings.cardCornerRadius` hardcodes `16` as an INDEPENDENT literal, NOT linked to `Layout.cornerXL`. If the scale is ever updated (e.g., macOS 27 ships, cornerXL becomes 18), Settings cards will stay at 16 and visually diverge.

Same issue for `cardPadding = 16` (should be `Layout.spacingLg`).

- Duplicate literal radius: [AppConstantsSettings.swift:5](file:///Users/jack/Projects/osx/osx-ide/Compass/Services/AppConstantsSettings.swift#L5-L5)
- Scale-source-of-truth cornerXL: [AppConstantsLayout.swift:28](file:///Users/jack/Projects/osx/osx-ide/Compass/Services/AppConstantsLayout.swift#L28-L28)

**Recommendation:**
```swift
static let cardCornerRadius = AppConstants.Layout.cornerXL
static let cardPadding      = AppConstants.Layout.spacingLg
```

---

### P3 — Low Impact / Code Quality

#### P3-1. `fatalError` in NSViewRepresentables

Prevents Storyboard/Nib instantiation, breaks SwiftUI previews in some configurations, and violates plans/eliminate-crash-hazards.md.

- [InlineCompletionDropdownView.swift:28](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/InlineCompletionDropdownView.swift#L28-L28) — `fatalError("init(coder:) has not been implemented")`
- [LineNumberRulerView.swift:53](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/LineNumberRulerView.swift#L53-L53) — same

**Recommendation:** Replace with a non-fatal fallback that returns an empty view and logs an error to ErrorManager.

---

#### P3-2. `Task.sleep` Magic Nanosecond Durations

5 unrelated Task sleeps with unlabeled nanosecond values, no central time token:

| File | Line | nanoseconds | Semantics (inferred) |
|---|---|---|---|
| [MessageListView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/MessageListView.swift#L72-L72) | 72 | 50_000_000 (50ms) | Render debounce |
| [MessageListView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/MessageListView.swift#L136-L136) | 136 | 5_000_000_000 (5s) | Auto-scroll debounce |
| [LogsPanelView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/LogsPanelView.swift#L51-L51) | 51 | 100_000_000 (100ms) | File-tail poll interval |
| [DependencyContainer.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Services/DependencyContainer.swift#L167-L167) | 167 | 200_000_000 (200ms) | Warm-up wait |
| [DependencyContainer.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Services/DependencyContainer.swift#L294-L294) | 294 | 5_000_000_000 (5s) | Indexer cooloff |

`AppConstantsTime` currently defines only `errorAutoDismissDelay` at 3s.

**Recommendation:** Add time constants: `renderDebounceMs = 0.050`, `autoScrollDebounceS = 5.0`, `logTailPollIntervalS = 0.100`, `warmupWaitS = 0.200`, `indexerCooloffS = 5.0`. Use `try? await Task.sleep(for: .seconds(AppConstantsTime.autoScrollDebounceS))`.

---

#### P3-3. `ReasoningOutcomeMessageView` Reimplements Chevron/Bubble Pattern Without Sharing Code

ReasoningOutcome bubble uses the same header-icon + chevron expand pattern as `ReasoningMessageView` and `ToolExecutionMessageView`, yet rolls an independent implementation. Small styling drifts already exist: no explicit `caption2.weight(.medium)` on its chevron, different label kerning, etc.

- [ReasoningOutcomeMessageView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ReasoningOutcomeMessageView.swift)
- Peer: [ReasoningMessageView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ReasoningMessageView.swift)
- Peer: [ToolExecutionMessageView.swift](file:///Users/jack/Projects/osx/osx-ide/Compass/Components/ToolExecutionMessageView.swift)

**Recommendation:** Extract a shared `ExpandableMessageHeader<Icon: View, Title: View>` component.

---

## Missing Design Tokens (Actionable Backlog)

| Category | Missing Token | Occurrences Found | Suggested Default |
|---|---|---|---|
| Sizing | `statusDotSize: CGFloat` | 3x (EditorTabBar, SettingsStatusPill, IndexStatusBar) | 6 |
| Sizing | `typingIndicatorDotSize: CGFloat` | 1x (MessageListView) | 7 OR unify to 6 |
| Sizing | `regularIconSize: CGFloat` | 4x (ToolExec msg ×3, AIChatPanel) | 16 |
| Sizing | `gutterSeparatorWidth: CGFloat` | 0x (not yet implemented — Issue P0-2) | 1 |
| Sizing | `chatInputMinHeight: CGFloat` | 1x (ChatInput, unbounded by token) | 40 |
| Sizing | `modalWidthNewProject: CGFloat` + modalHeight | 1x (NewProjectDialog.swift) | 400 × 250 |
| Sizing | `progressBarWidth: CGFloat` | 2x (LocalModelSettingsView) | 420 |
| Overlay | `popoverWidthCompact: CGFloat` | 2x (240) | 240 |
| Overlay | `popoverWidthDefault: CGFloat` | 3x (300) | 300 |
| Overlay | `popoverWidthWide: CGFloat` | 1x (320) | 320 |
| Overlay | `popoverWidthExtraWide: CGFloat` | 1x (340) | 340 |
| Settings | `stepperWidth: CGFloat` | 1x (160) | 160 |
| Settings | `keyStatusWidth: CGFloat` | 2x (260) | 260 |
| Settings | `validateBtnWidth: CGFloat` | 1x (120) | 120 |
| Settings | `promptModeWidth: CGFloat` | 1x (220) | 220 |
| Time | `renderDebounceMs: Double` | 1x | 0.050s |
| Time | `autoScrollDebounceS: Double` | 1x | 5.0s |
| Time | `logTailPollIntervalS: Double` | 1x | 0.100s |
| Time | `warmupWaitS: Double` | 1x | 0.200s |
| Time | `indexerCooloffS: Double` | 1x | 5.0s |
| Color | `gutterSeparator: Color` | 0x (Issue P0-2) | `AppConstants.Color.separatorDefault` |

---

## Recommended Fix Ordering

Execute in this order (each pass is independent; break between them for build validation):

1. **Pass A — Chrome polish (P0-1, P0-2):**
   - Inset PanelDivider overlays below headerHeight.
   - Add 1pt gutter divider in ModernLineNumberRulerView.
   - Clip Minimap Divider below the TabBar (add new `IDEPanelDivider` while here).
   - Adds the `gutterSeparator` / `IDEPanelDivider` tokens above.

2. **Pass B — Adjacent controls (P0-3):**
   - Convert model selector from Button+popover → Menu to match mode selector.
   - Add `.weight(.medium)` to reasoning chevron.
   - Add 2 baseline previews that freeze this.

3. **Pass C — Liquid glass everywhere (P0-4):**
   - 8x `.glassEffect(.regular)` → `nativeGlassBackground(.panel)`.
   - Remove ChatInputView solid-color underlayer.
   - Apply glass to: FileExplorer sidebar, Settings window root, IndexStatusBar strip.

4. **Pass D — Settings 3→1 idioms (P2-1):**
   - Wrap AI sections in SettingsCard.
   - Rewrite AgentSettingsTab: Form → ScrollView/SettingsCard/SettingsRow.

5. **Pass E — Magic-number audit (all P1 + P2-3 + P3 tokens):**
   - Add the 20 missing tokens above (size/overlay/settings/time/color).
   - Grep-replace 80+ literals.
   - Link `cardCornerRadius` to `cornerXL`, `cardPadding` to `spacingLg`.

6. **Pass F — Divider consolidation (P2-2):**
   - Ship `IDEPanelDivider` in Pass A; now roll out `IDESectionDivider` to Divider() sites.
   - Add SwiftLint rule for `Divider(` without the helper.

7. **Pass G — Minor cleanup (P3):**
   - Remove fatalErrors, add `Task.sleep(for:)` helpers, extract `ExpandableMessageHeader`.
