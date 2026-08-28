# Design Standards

Authoritative UI/UX rules for **Compass**. The goal is a consistent, Apple macOS‑native
appearance across every surface (chat panel, settings, overlays, status bars, dialogs).

## Design direction: quiet workspace chrome

The editor is the primary surface. Do not add a persistent in-content top bar or a ribbon
of actions above panels. Use the macOS menu bar and keyboard shortcuts for commands; keep
the bottom status bar for concise, contextual state.

**Protected title-bar controls.** The AI mode selector and the model picker are critical,
always-available controls and live in the window toolbar's trailing edge (right side) as a
shared pill idiom (`IDECapsuleDropdownLabel`). They must never be removed, hidden, or
relocated to Settings-only: quick model/mode switching is core usability. Restricting them
to the app menu or Settings is a regression, not a simplification.

The title bar may otherwise contain only optional, user-toggleable actions; it must never
dominate the workspace.

When an action must be visible within a panel, prefer `IDEIconButton`: a 28 pt accessible
hit area with no permanent background. Its label belongs in VoiceOver and hover help, not
in the editor chrome. Use `WorkspacePanelHeader` only where an orientation label is needed;
it intentionally has no permanent action strip.

These rules exist to prevent the UI regressions we have already hit — most notably the
mode selector and model selector rendering as two differently‑sized "dropdown bubbles"
because one was a native `Picker` and the other a hand‑rolled `Button` (`AIChatPanel.swift`).

## 1. Source of truth

**All spacing, corner radii, colors, control heights, and shared sizes MUST come from
`AppConstants`** (`Compass/Services/AppConstants*.swift`). Never hardcode these values in
component code.

If a value you need does not exist as a token, **add it to the appropriate `AppConstants*`
file** (and update this document), do not inline a magic number.

```
AppConstants.Layout    // spacing scale, header height, semantic corner radii
AppConstants.Color     // semantic colors (use these, not raw NSColor/.labelColor)
AppConstants.Settings  // settings-form metrics (card padding, icon size, picker widths)
AppConstants.Overlay   // overlay/popover container metrics
AppConstants.Editor    // editor font base
AppConstants.Layout    // panel limits, divider and hit-target metrics
```

## 2. Spacing — 8pt scale only

Use `AppConstants.Layout.spacing*`. Do not use arbitrary insets like `.padding(.horizontal, 14)`
or `.padding(.vertical, 10)` outside the token scale.

| Token | Value | Use for |
|---|---|---|
| `spacingXXS` | 2 | icon‑to‑label micro gap |
| `spacingXS`  | 4 | tight gaps inside controls |
| `spacingSm`  | 8 | default intra‑control / list gap |
| `spacingMd`  | 12 | card inner padding, row gap |
| `spacingLg`  | 16 | section gap, container padding |
| `spacingXL`  | 24 | group separation |
| `spacingXXL` | 32 | major separation |
| `spacingXXXL`| 48 | screen‑level separation |

✅ `.padding(.horizontal, AppConstants.Layout.spacingSm)`
❌ `.padding(.horizontal, 14)`

## 3. Corner radii — semantic tokens only

| Token | Value | Use for |
|---|---|---|
| `cornerSm` | 6  | toolbar / small chrome |
| `cornerMd` | 8  | popovers, small cards |
| `cornerLg` | 12 | panels, cards, inputs |
| `cornerXL` | 16 | large containers, sheets |

`cornerRadius: 18` (seen in `ChatInputView`) is **not** in the scale and is a violation.
`cornerRadius: 0` is allowed only for full‑bleed edges that meet a window/panel border.

✅ `.background(RoundedRectangle(cornerRadius: AppConstants.Layout.cornerLg, style: .continuous))`
❌ `RoundedRectangle(cornerRadius: 18, style: .continuous)`

## 4. Colors — semantic tokens only

Always use `AppConstants.Color.*`. Do not reach for `Color(nsColor: .labelColor)`,
`.secondaryLabelColor`, `.separatorColor`, or `Color.accentColor.opacity(...)` directly in
component bodies — centralize in `AppConstants.Color` so themes stay consistent.

| Token | Maps to |
|---|---|
| `surfaceBackground` | `.windowBackgroundColor` |
| `surfaceSidebar` / `surfaceCard` | `.controlBackgroundColor` |
| `textPrimary` | `.labelColor` |
| `textSecondary` | `.secondaryLabelColor` |
| `textTertiary` | `.tertiaryLabelColor` |
| `accentDefault` | `.accentColor` |
| `accentSubtle` | `.accentColor.opacity(0.12)` |
| `separatorSubtle` / `separatorDefault` | `.separatorColor` (tinted / plain) |

For glass surfaces use `View.nativeGlassBackground(_:cornerRadius:showBorder:)` with
`NativeGlassSurface` cases (`.header`, `.toolbar`, `.sidebar`, `.panel`, `.popover`, `.sheet`)
rather than hand‑rolling materials.

## 5. Control heights & dividers

- **Standard header height** = `AppConstants.Layout.headerHeight` (30). Every header bar
  (chat panel, bottom panel, sidebar) must use this single value. Do not hardcode
  `.frame(height: 32)` (seen in `AIChatPanel`).
- **Dividers** must use `AppConstants.Color.separatorDefault`, not a raw `Rectangle().foregroundStyle(.separator)`.
  Prefer `nativeGlassBackground(.header)` which already paints the material; add the 1px
  separator as `.overlay(alignment: .bottom) { Rectangle().fill(AppConstants.Color.separatorDefault).frame(height: 1) }`.
- **Panel splitters** use `AppConstants.Layout.panelDivider*` and `AppConstants.Color.dividerHover`.
  Never give a resizable splitter a literal hit width or a raw separator color.
- **Status bar** height is `AppConstants.Layout.statusBarHeight`; status content is concise
  and descriptive. Detailed operational metrics belong in an optional popover or diagnostics view.

## 6. Dropdowns / selectors (the mode/model rule)

Any two controls that serve the same role and sit next to each other **MUST share one
component and one visual idiom**. This is the rule that was violated by the mode selector
(native `Picker(.menu)`) sitting beside the model selector (custom `Button` + `popover`),
producing different heights, fonts, and hit areas.

Rules:
1. **Prefer native `Picker` with `.pickerStyle(.menu)`** for both. A `Picker` can carry a
   custom label if you need an icon/status inside the bubble, while still rendering with
   native menu chrome and consistent metrics.
2. If a richer bubble is required (icon + status text + chevron), build **one** shared
   `CapsuleDropdown` (or equivalent) component and use it for *all* such selectors — mode,
   model, provider, reasoning, language. Do not mix native‑menu and custom‑button in the
   same toolbar.
3. **Matched geometry**: same height, same font, same horizontal padding, same chevron size.
   Either fix both widths (e.g. `.frame(width: 120)`) or let both size intrinsically — never
   one fixed and one auto.
4. **Labeling consistency**: if one shows a title prefix ("Mode"), related selectors should
   follow the same labeling convention.

## 7. Typography

- Base UI text size derives from `uiState.fontSize` (default `AppConstants.Editor.defaultFontSize` = 12).
- Use system text styles (`.body`, `.caption`, `.headline`) before reaching for
  `.font(.system(size: N))`. When a specific size is unavoidable, introduce a token
  (e.g. `AppConstants.Layout.fontCaption`) instead of `.system(size: 8)` / `.system(size: 11)`
  scattered across files.
- Secondary/tertiary labels use `AppConstants.Color.textSecondary` / `textTertiary`.

## 8. Overlays, popovers & dialogs

- Use `AppConstants.Overlay` metrics for container padding, corner radius, min sizes, and
  field widths. Do not hardcode `frame(width: 320, height: 400)` popovers (seen in
  `AIChatPanel`) — add/use overlay tokens.
- Overlay corner radius should be `AppConstants.Overlay.containerCornerRadius` (12), matching
  `cornerLg`.

## 9. Protected patterns

The editor pill‑tab architecture in `EditorTabBar.swift` / `AIChatPanel` tab section is a
**hard‑won, do‑not‑alter** pattern documented in `AGENTS.md` ("Pill Tab Implementation").
Do not "clean up" that pattern in the name of consistency — it is the reference for how a
capsule control should be built. New capsule controls should mirror it.

## 10. Enforcement

1. **Agents/PR authors** read `AGENTS.md`, which links here. Follow the tokens above.
2. **SwiftLint** runs on the `Compass` target and includes a guardrail rule
   (`hardcoded_corner_radius`) that warns on literal `cornerRadius:` values outside the token
   scale. Treat warnings as must‑fix for UI code.
3. **No magic numbers** for spacing/radius/color/size in component bodies (see §1).

## 11. PR checklist

- [ ] No new hardcoded `cornerRadius:`, spacing, or color literals.
- [ ] New sizes added to `AppConstants*`, not inlined.
- [ ] Adjacent controls of the same role share one component/idiom (§6).
- [ ] Headers use `AppConstants.Layout.headerHeight`; dividers use `AppConstants.Color.separatorDefault`.
- [ ] Glass surfaces use `nativeGlassBackground(_:)` / `NativeGlassSurface`.
