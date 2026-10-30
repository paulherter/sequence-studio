# Design System (proposal + audit)

Step 1 of NEXT "DESIGN SYSTEM + CONSISTENCY PASS" (DECISIONS 2026-10-03 "One design system"). Read-only audit of
`Packages/SQEditorUI/Sources` and `App/Sources` against `Theme.swift`, using ui-niveau / apple-design / brand-basis.
Part 1 is the ONE token set to migrate to (replaces Theme.Fonts/Spacing/Radius/Metrics where they differ).
Part 2 lists every outlier found, grouped by area, most visible first. Line numbers as of commit 6d18c18d.

## Token API (SQEditorUI `Theme.swift` + `ThemeTokens.swift`; use these names when migrating)
- UI scale (`UIScale`, SQUIKit, defaults `sq.ui.scale`, steps 0.8 0.9 1.0 1.1 1.25 1.5): `Theme.Typography` sizes, `Theme.Row` heights and `Theme.Metrics` heights multiply by `UIScale.launch` through `UIScale.scaled(_:)`; a new height token uses it. API: `UIScale.increase() / decrease() / reset() / set(_:)`, `pending`, `restartNeeded`. Applies on next launch.
- Type (`Theme.Typography`, not `Theme.Type` = metatype): NSFont `caption captionStrong body bodyStrong title titleStrong display emptyHeading` (`emptyHeading` = 15 semibold, the title of a large empty state such as the empty Pro page);
  SwiftUI `captionFont captionStrongFont bodyFont bodyStrongFont titleFont titleStrongFont displayFont`;
  sizes `captionSize bodySize titleSize displaySize`; symbols `symbolSmall symbolInline symbolChrome` (with `Theme.symbol(_:size:)`).
- Rows (`Theme.Row`): `standard list menu property sectionHeader` 24, `thumb` 28, `panelHeader` 28, `columnHeader` 22,
  `topBar` 36, `statusBar` 22, `timelineHeader` 24, `control` 20, `controlLarge` 24, `swatch` 38x20.
- Radius (`Theme.Radius`): `none` 0, `small` 3, `control` 5, `overlay` 8. Deprecated aliases: `clip row check` → small,
  `field` → control, `card` → overlay, `window` → none (the compiler's fix-it renames them).
- Spacing (`Theme.Spacing`, unchanged): `xxs xs sm md lg xl` = 2 4 8 12 16 24, `iconToLabel` 6, `inset` 6, `treeIndent` 14 (one nesting step of every tree list: Library tree, Effects folders, Project folders).
- State (`Theme.State`): `controlRest controlHover pressed rowHover selected selectedSegment selectedFocused focusRing
  panelFocusRing focusRingWidth dropTargetFill disabledText disabledAlpha primary primaryPressed onAccent captionPlateAlpha`.
- Separator (`Theme.Separator`): `hairline divider width`.
- Item-type colors (Project panel): no tokens of their own. `LabelColor` (SQCore) is the single source for timeline clips and Project items (`Project.clipLabels(of:)`, `ProjectPanelModel.tints(of:)`, `LabelColor.fill`); `Theme.Colors.clip*` derive from it; `clipFolder` is the only extra (= `binDefault`).
- On picture / clips (`Theme.OnPicture`): `stroke shadow guideSnap hudFill guide clipBadgeFill clipBadgeEdge clipGhostAlpha offlineClip`.
- Palettes (`Theme.Palette`): `marker(_:)`, `shortcutGroup(_:)`, `graphCurve` (`whiteBalance` still to move from the color controls).
- Surfaces / text / fills / accent / semantic stay in `Theme.Colors`. Round 2 (design v11): neutral grays (titlebar #1f1f1f, panel #1a1a1a,
  content #161616, timeline #121212, lane #151515, overlay #262626, divider #0b0b0b), `label` 88 %, `label3` 52 % (text tokens are opaque composites over #1a1a1a: E3 / A8 / 91), `selection` 14 %,
  `playhead` white 92 %. Accent is violet since 2026-10-13: dark #A56BFF, light #7A33E0, `accentFill` #7C3AED (the blue channel dot is `Palette.channelBlue`, not the accent). Playhead K1 (`Theme.PlayheadSkin`, ThemePlayhead.swift): `lineWidth` 2, `headSize` 12 x 12 (even, centered on the line), `headTop` / `headBottom` porcelain gradient, `headOutline` (light only), `headPath(centerX:top:)`, `lineFrame(centerX:y:height:)`, `drawHead(centerX:top:)`; every ruler, lane and curve view uses it. `Theme.IconGradient.stops`: export progress and finished only. New: `keyframeSelected` (= accent), `inOutTint` `inOutEdge` `inOutWash`, `trackRowLine` 9 %, `trackHeaderLine` 12 %.
- Shape (round 2): `Metrics.capsule` 22 (= `quietButton` = `quietField`), `Radius.capsule(forHeight:)`, `Radius.checkbox` 4, `Radius.well` 8,
  `Metrics.checkbox` 14, `Metrics.sliderKnob` 10, `Metrics.sliderTrack` 2, `Row.control` 22, `State.focusLine` / `focusLineWidth` (inner 1.5 px accent,
  `ControlShape.drawFocusLine`), `State.disabledAlpha` 0.4. Buttons, popups, segments, scrub / search fields are capsules; ScrubField value text is accent.
- Motion (`Theme.Motion`, WP-A): `fast` 0.12 `standard` 0.2 `slow` 0.3 (s); `Curve.linear/.easeOut/.easeInOut` with
  `value(_ t:) -> Double` (pure) and `timingFunction` (CAMediaTimingFunction); `spring` (SwiftUI Animation);
  `duration(_:)` = 0 when Reduce Motion is on; `@MainActor fadeIn(_ window:)` / `fadeOut(_ window:completion:)` for popovers, menus, sheets.
- Selection (`Theme.Selection`, WP-A; one style app-wide, neutral, accent only for focus): `fill` (unfocused list/tile/layer),
  `fillFocused` (its panel has focus), `hover` (= State.rowHover), `outline` + `outlineWidth` (timeline objects: clips,
  transitions, gaps), `text`, `secondaryText`; `@MainActor static func draw(in:focused:)` fills a rect.
- Controls grid (`Theme.Inspector`; read it through `ControlsGrid`, the ONE definition every Controls row uses, at
  every panel width; all numbers are between element bounds): `ringX` 8 (toggle column 8-22, `toggleWidth` 14, center
  15: chevron, animate diamond, row checkbox), `columnGap` 6 (the one gap between neighboring columns and controls),
  `nameX` 28 `nameWidth` 70 (label column 28-98), `controlX` 104, `valueWidth` 50 (value columns 104 / 160 / 216),
  tail column ending at `trailing` 12 (`resetWidth` 22 reset or Open chevron, `navigationWidth` 72 key navigation (divisible by 3 and 4: whole-point slots of 24 or 18)),
  `labelHeight` 14, `rowHeight` 28 (= `Row.control` 22 + `columnGap`, so controls of two rows are 6 apart too),
  `headerHeight` 24 (= Row.sectionHeader), `sectionGap` 4 (= Spacing.xs, before every section header but the first),
  `iconSlot` 18; fixed control sizes: `timecodeWidth` 78 (a timecode field), `popupWidth` 120 (a popup beside a
  label), `graphHeight` 120 (the inline speed curve), `bandsHeight` 84 (the EQ bands of a track's audio).
  `ControlsGrid(width:)` gives the frames: `toggleFrame`, `toggleBox`, `labelFrame`, `valueFrame(n)`,
  `fillFrame`, `controlFrame`, `resetFrame`, `navigationFrame`. No row carries a padding number of its own.
- Controls rows report their frames (`ControlsRowProbing.rowProbe`: toggle, label, controls, tail); the layout test
  `ControlsSkeletonLayoutTests` checks them for a text, shape, graphic, video, audio and caption selection at 324 / 364 /
  520 pt. A new row type conforms to it. Auto Layout rows use `TextBlockRow` (label + `GridStack`, which puts the
  controls' bounds, not their alignment rects, on the grid).

### Components (WP-A; SQEditorUI, public, AppKit; every state: default hover pressed selected disabled focused)
- `ScrubField` (number field). Rules: drag scrubs (Shift x10, Option/Cmd x0.1), single click types, double-click resets
  (`defaultValue` or `onReset`), Enter commits, Esc cancels typing AND an open drag/arrow/wheel gesture (value back to the
  start; `onCancel(start)` if set, else begin/change/end restores it), arrows step, scroll wheel steps only with Option
  held while hovered or focused (Option+Shift x10, Option+Cmd x0.1; one burst = one undo step). New API:
  `var onCancel: (@MainActor (Double) -> Void)?`, `func cancelGesture()`. Pure: `ScrubMath.wheelAccepts(option:hovered:focused:)`,
  `ScrubMath.wheelMultiplier(shift:command:)`, `ScrubMath.wheelValue(_:notches:step:shift:command:range:)`,
  `ScrubMath.wheelDelta(deltaX:deltaY:)`, `ScrubMath.WheelAccumulator { mutating func add(delta:precise:) -> Int }` (8 pt/notch),
  `ScrubMath.resetTarget(current:default:range:) -> Double?` (nil = nothing to do).
- `SQSlider` (+ `defaultValue: Double?`, `onBegin/onChange/onEnd`, double-click reset, drag Shift x10 / Option x0.1 relative
  to the press, Option+wheel 1 % of the range per notch, Esc cancels, `resetToDefault()`, hover thumb, arrow cursor always, no halo). Pure:
  `SQSlider.dragValue(start:deltaX:trackWidth:min:max:shift:option:) -> Double`.
- `NumericSlider(value:range:defaultValue:step:decimals:unit:)`: NSView, slider + coupled ScrubField (field width
  `fieldWidth` 52). `value`, `range`, `defaultValue`, `step`, `decimals`, `unit`, `isEnabled`, `onBegin/onChange/onEnd`
  (one triple per gesture from either part), `slider`, `field`.
- `IconScrubField(icon:tip:)` (SQUIKit): an icon (no word) left of a plain ScrubField, tooltip names the value; `field` is the
  ScrubField to configure. Used in pairs on a full-width row (text panel: letter and line spacing). A full-width row
  (`ControlsRowProbe.fullWidth`) has no label: its first control starts at `ControlsGrid.labelX`, gaps and trailing inset as everywhere.
  Text panel icons are `SQIcon` `text*` / `shadowAngle`; `AppearanceRow.addEyedropper` adds the screen picker in value column 2.
- `KeyframeControlState` (pure): `ring: ScrubKeyframeState`, `showsNavigation`, `canGoPrevious`, `canGoNext`, `canToggleKey`,
  `keyIsOn`; `static let off`; `static func resolve(animated:onKey:hasPrevious:hasNext:playheadInRange:)`.
- `KeyframeControls(propertyName:onToggleAnimation:onPrevious:onToggleKey:onNext:)` (@MainActor class): `ring:
  KeyframeToggleView` (leading slot) + `navigation: KeyframeNavigationView` (prev / diamond / next IconButtons, trailing);
  `var state: KeyframeControlState`, `var isEnabled`; `install(in:)`; `layout(rowBounds:ringX:navigationMaxX:)` (defaults = Theme.Inspector).
  `KeyframeNavigationView.width` = 3 x iconSlot; its buttons `previous`, `key`, `next`. Tooltips: "Animate <Name>",
  "Previous Keyframe", "Add/Remove Keyframe", "Next Keyframe". Old ring/nav sets in EC rows, PropertyRow, Graphics and
  Color are not migrated yet (WP-B/G/H move them onto this).
- `EmptyStateView(title:hint:symbol:)`: NSView, centered title (body, label2) + hint (caption, label3, may name a key);
  `title`, `hint`, `symbol` settable, `titleLabel`/`hintLabel`; transparent to clicks and drops. SwiftUI twin `EmptyStateLabel(title:hint:)`.
- `IconButton` (open, subclass of SQButton `.icon`): `init(symbol:label:command:size:handler:)`, `handler`, `isSelected`
  (accent glyph + selected fill), `hoverCursor: NSCursor?`, `setSymbol(_:tint:size:)`, `setKeyDiamond(onKey:)`. Hover fill,
  pressed fill, disabled alpha, focus ring under full keyboard access. `ClosureButton` = typealias (old call sites).
- `FlatSelectionRowView` (public NSTableRowView): `Theme.Selection.fill` / `fillFocused` when the table is first responder,
  optional `showsHover`. Use for every NSTableView/NSOutlineView `rowViewForRow`.
- `InspectorSectionHeader(title:hasEnableToggle:isExpanded:)`: 24 pt titlebar band, chevron, title, optional SQCheckbox,
  trailing accessories (`addAccessory(_:)`); `isExpanded`, `isSelected`, `isEnabledToggleOn`, `toggleExpanded()`,
  `onToggleExpanded`, `onToggleEnabled`; hover. `InspectorSection(title:key:hasEnableToggle:defaultOpen:)`: NSStackView
  `header` + `body`, `addRow(_:)`, `isExpanded`, `onLayoutChange`; expand state persisted under `sq.inspector.open.<key>`
  (nil key = not persisted).
- `InspectorRow(title:control:controlWidth:keyframes:)`: one grid row (28 pt) on the Controls grid (ring, name, control,
  trailing keyframe navigation); `title`, `nameLabel`, `control`, `controlWidth`, `keyframes`, `isSelected` (Selection
  fill), `isEnabled` (dims the name, disables control + keyframes), hover.
- Base controls now hover (WP-A): `SQCheckbox` (off-box edge `label2`), `SQTextField` / `SQSearchField` (edge `fillPressed`,
  focused `State.focusRing`), `SQButton.isHovered` settable internally.
- `SQDivider(orientation:style:)`: `.horizontal/.vertical`, `.hairline` (rows/sections) or `.pane` (pane splits); 1 pt. Docked panels are not split by a line: 3 pt cards 2 pt apart (`Spacing.paneDivider`, `Radius.panel`).
- `Tooltip`: `Tooltip.text(_ name:shortcut:)` -> "Name (⌘K)" (name only without a key; trims, drops a trailing period),
  `Tooltip.text(_ name:command:map:)` (key from CommandMap), `Tooltip.text(_ name:binding:)`; `NSView.setTooltip(_:command:)`.
  `KeyboardListing.tip` stays and uses the same format.

Exempt (not UI chrome, keep literal): rendered content colors (TextStyleLibrary, TextInspectorModel defaults,
CTAEndCard, KeywordAtPlayhead/ClipSectionLogic shadows, caption/karaoke defaults), color-model conversions
(`NSColor(srgbRed: c.red …)` from model values), hue wheels/hue strips (ColorWheelControl:139, ColorCurveEditor:106,
ColorClipStripView:48), bitmap cursors (TimelineCursors, OverlayCursors), SnapshotDriver, NSOpen/SavePanel.

---

## 1. Token set

### 1.1 Reference: the workspace buttons (Edit | Color)
`App/Sources/Toolbar.swift:38` → `SQSegmented` (`SQSegmented.swift:111-120`): height `Metrics.barControl` 22,
radius `Radius.control` **5** (track and selected segment), 11 pt medium, track `fill2`, selected `fillPressed`.
So the control family radius is 5; floating layers keep 8 (D4); docked panels 0.

### 1.2 Type (SF Pro, monospaced digits everywhere; 4 sizes x 2 weights)
Weights: **Regular** and **Medium** only. Semibold, light and bold go (brand-basis: no bold headings).

| Token | Size / weight | Roles |
|---|---|---|
| `caption` | 10 regular | ruler, column headers, status bar, meter scale, clip names on the timeline, badges, HUD |
| `captionStrong` | 10 medium | menu section headers, Effect Controls group titles, clip badges (FX, speed %), key caps |
| `body` | 11 regular | default UI text: rows, controls, fields, tabs, inspector labels, dialog message |
| `bodyStrong` | 11 medium | names, selected tab, panel section titles (Effect Controls, Color, Text, Clip sections), segmented |
| `title` | 13 regular | menus (rows + shortcuts), dialog/sheet body where 11 is too small |
| `titleStrong` | 13 medium | dialog / sheet / export title |
| `display` | 18 regular | viewer timecode, Quick Apply search field |

(`display` is the 4th size; it has no medium. 9, 9.5, 10.5, 11.5, 12, 12.5 disappear.)
Symbols: one weight (`.light`), sizes 9 (in 10 pt rows/chips), 11 (inline with body), 13 (chrome / tool buttons).

### 1.3 Spacing (4 pt grid)
`2 / 4 / 8 / 12 / 16 / 24`. Named exceptions only: `iconToLabel` 6, `controlTextInset` 6 (text inside fields),
`menuInset` 5 (row inset in floating lists, = overlay 8 − highlight 3). Off-grid literals 5, 7, 9, 10, 14, 18, 22 map
to the nearest step (10 → 8 or 12, 14 → 12/16, 22 → 24). Panel content inset: 12 left/right, 8 top/bottom.
Dialog/sheet padding 16, gap 12; button row gap 8. Inspector indent ladder: 8 (section), 28 (property name), 104 (control).

### 1.4 Heights per family
| Family | Height | Members |
|---|---|---|
| Top bar | 36 | TopBarView |
| Panel header (tab strip) | 28 | TabStrip, panel search/header rows; `PanelID.headerHeight` must equal it |
| Timeline header / sequence tabs | 24 | TimelineHeaderBar, SequenceTabsView |
| Status bar | 22 | |
| Monitor header / footer | 32 / 32 | (now 34 / 32) |
| **Menu row** | 24 | SQMenu rows and headers, Quick Apply rows, popup lists |
| **List row** | 24 | Project list, Library sidebar, Effects list, Captions list, Keystones, template headers, Start window recents, keyboard shortcut list, settings rows |
| Media row (thumbnail in row) | 28 | Library media list only |
| Column header | 22 | QuietHeaderCell |
| **Controls row** | 28 | every row of the Controls column (`Theme.Inspector.rowHeight`): parameters, text block, shape, template, audio. All Captions (`CaptionReadListView`) uses the list row, 24, on the same columns |
| **Property row** | 24 | Color inspector rows, Text panel, Graphics panel, Transition controls, Track audio inspector, Export settings, Sequence settings |
| Section header row (inside a panel) | 24 | Effect Controls sections, ClipSectionsView, Color sections, Text panel sections |
| Tracks | V1 32, A1 26, others 20; caption rows 20 (now 22) | user-resizable content |
| Control (in panels) | 20 | SQButton, SQPopup, SQTextField, SQSearchField, ScrubField, SQSegmented in panels, TextPanel popup |
| Control large (floating layers + top bar) | 24 | dialog/sheet buttons + fields, export dialog, Quick Apply, top bar controls (now 22) |
| Swatch | 38 x 20 | SQColorWell everywhere (now 34x20, 36x20, 40x20) |

### 1.4a Modal shell tokens (`Theme.Modal`, SQUIKit/OverlayTokens.swift)
`scrimAlpha` 0.50, `radius` 14, `headerHeight` 56, `footerHeight` 68, `bodyPadV` 20, `bodyPadH` 24, widths `widthXS` 360 / `widthS` 440 /
`widthSList` 480 / `widthM` 600 / `widthL` 860 x `heightL` 640, `labelColumn` 104, `labelColumnL` 132, `edgeMargin` 24. Component: `SQModal` (DESIGN.md, Overlays). `SQDialog.cardHeight` fixes the card height (Settings: `heightL`); form rows of the L modals: `SQFormRow` (SQEditorUI).

### 1.5 Radii (derived from 5)
| Token | Value | Use |
|---|---|---|
| `none` | 0 | docked panels, panes, tabs, sequence tabs, timeline clips container |
| `small` | 3 | chips, checkbox, swatch, clip, slider track, inner highlight inside a radius-8 layer (8 − inset 5) |
| `control` | **5** | buttons, popups, fields (incl. ScrubField, dialog field, hex field), segmented, tool buttons, grid tiles and their selection (Project icons, Library grid, Text style grid, card import tiles) |
| `overlay` | 8 | menus, popovers, dialogs, sheets, Quick Apply, splash, trim monitor card, Start window cards |
Removed: `field` 4, `card` 6, `row` 3 (→ small), `clip` 3 (→ small), `check` 3 (→ small), literal 1/1.5/2/2.5/4.

### 1.6 Colors (roles; values unchanged unless noted)
Surfaces (slightly warm, same luminance as the old grays): `titlebar` 201F1D, `panel` 1B1A18, `content` 171614,
`timeline` 131210, `lane` 161513, `viewer` 0C0C0C (scopes, export preview; stays neutral for grading), `monitorBackdrop` 2C2C2C (area behind the Program / Source / Color picture, = `Presenter.surround`), `overlay` 242321 (+ `overlayEdge` white .09), `scrim` black .38.
Text: `label` .86, `label2` .62, `label3` .46 (also = disabled text). Separators: `separator` white .075 hairline 1 px;
`divider` is the surface behind the panel cards (the 2 pt gaps and the 2 pt outer margin).
Fills: `fill` .11 (control rest), `fill2` .06 (track / quiet rest), `fillHover` .16, `fillPressed` .22, `field` black .28 + `fieldEdge` .10.
States (one token per state, everywhere):
| State | Control box | Row / tile / menu item |
|---|---|---|
| hover | `fillHover` | `rowHover` = white .08 (= today's `overlayHover`, renamed; used by menus, lists, grids, SwiftUI rows) |
| pressed | `fillPressed` | `fillPressed` |
| selected | segmented: `fillPressed` | `selection` white .10 (lists, grids, tiles, keyboard list, card import) |
| selected + focused panel | — | `accentTint` blue .22 (targeted track, Library/Project grid when panel focused) |
| primary action | `accent` / pressed `accentFill`, text `onAccent` white | — |
| focus | 1 px `accentRing` (fields, scrub fields, search) | panel: 1 px `focusRing` |
| drop target | 1 px `accentRing` + `accentTint` .10 fill (DockDrag look) | same |
| disabled | text `label3`, glyph/fill alpha `disabledAlpha` 0.45 | same |
New tokens needed: `onPicture` white / `onPictureShadow` black .5 (transform, crop, text-edit overlays), `guideSnap`
(FF4099 today), `hudFill` (= viewerHUD), `clipBadgeFill`/`clipBadgeEdge` (white .95 / black .6 used by FX, speed,
keystone badges), `clipGhost` (alpha .55 of clip color), `offlineClip` 6B2A26, `tooltipFill` (graph editor FFF7B0 → use `overlay`).
Palettes as Theme data, not view literals: `Palette.marker` (RulerView), `Palette.shortcutGroup` (KeyboardLayoutView),
`Palette.graphCurve` (GraphEditorView, replaces unused-elsewhere `curveX/curveY`), `Palette.whiteBalance` (ColorControls).
Semantic: `red`, `green`, `yellow`, `warning` (orange, also ripple); no `NSColor.system*`/`controlAccentColor`/`labelColor` anywhere
(they change with the user's macOS accent and appearance).

---

## 2. Outliers

Format: `file:line` – uses → should. E/ = `Packages/SQEditorUI/Sources/SQEditorUI/`, A/ = `App/Sources/`.

### 2.1 Menus / popovers / Quick Apply [migrated, Phase 2] (14)
| Where | Uses | Should |
|---|---|---|
| E/SQMenuListView.swift:33 | systemFont 12.5 (menu rows) | `title` 13 |
| E/SQMenuListView.swift:34 | 10.5 semibold (header) | `captionStrong` 10 medium |
| E/SQMenuListView.swift:35 | 11.5 (shortcut) | `title` 13 in `label3` |
| E/SQMenuListView.swift:118 | hover radius `field` 4 inside 8 / inset 5 | `small` 3 |
| E/SQMenuListView.swift:150-152 | swatch radius 3 literal, disabled alpha 0.4 | `Radius.small`, `disabledAlpha` 0.45 |
| E/SQMenuListView.swift:158-159 | `hex(0xFFFFFF,.10)`, radius 2 | `fieldEdge`, `small` |
| E/QuickApplyPanel.swift:63-64 | `hex(0x222222)`, `Radius.card` 6, hand-made card | `Overlay.style` (232323, 8) |
| E/QuickApplyPanel.swift:73 | systemFont 18 | `display` token |
| E/QuickApplyPanel.swift:213, 218-220 | field 26, buttons 32 high | `controlLarge` 24 |
| E/QuickApplyPanel.swift:288-290 | selected row = full `accent`, inset 6 | `rowHover` (menu look), inset 5, radius 3 |
| E/EasingCurvePopover.swift:237-240, 353 | field 22, button 24, chip 22x20 | `controlLarge` 24 / `control` 20 |
| E/EasingCurvePopover.swift:101 | `label3.withAlpha(.6)` | `label3` |
| E/SQMenuController.swift:291 | `SQMenuPopUpButton` keeps system button look | SQPopup drawing |
| E/TimelineContextMenu.swift:174-176, 252 | own hex→NSColor, radius 3, popup 24 | `Theme.hex`, `small`, `controlLarge` |

### 2.2 Panel chrome / top bar / lists shared (9)
| Where | Uses | Should |
|---|---|---|
| E/Workspace.swift:37 | `PanelID.headerHeight` 30 | 28 = `Metrics.panelHeader` (TabStrip draws 28) |
| A/SequenceTabsView.swift:62 | tab title `mini` 10 | `body` 11 like panel tabs |
| A/SequenceTabsView.swift:74-76 | selected = accent bar at top, rest `fill2` | same 2 px bottom underline as TabStrip |
| E/SQSegmented.swift:47 | `systemFont(11, .medium)` (no tabular digits, no token) | `bodyStrong` |
| E/SQSegmented.swift:119 | hover `fill2` on a `fill2` track (barely visible) | `fillHover` |
| A/Toolbar.swift:54-57 / Theme `barControl` | 22 | `controlLarge` 24 |
| E/QuietList.swift:22 | `selectionHighlightStyle = .regular` (system accent if no row view) | `.none` + FlatSelectionRowView by default |
| E/Library/LibraryPanelView.swift:73 | media table has no FlatSelectionRowView → system blue | FlatSelectionRowView |
| A/MainWindow.swift:44-45 | native `NSProgressIndicator` + NSButton (status ring) | own ring view in Theme colors |

**Migration status 2.2: DONE** except: QuietList keeps `.regular` selection style (Library media table now has FlatSelectionRowView; `.none` would stop row views drawing selection); `listRow` 22 -> 24 left to the list owners (2.6/2.7).

### 2.3 Timeline (22)
| Where | Uses | Should |
|---|---|---|
| E/TimelineView.swift:1699-1714 | white .55, black .75, white, 11 semibold mono, radius 4 | `hudFill`, `onClip`, `bodyStrong`, `small` |
| E/TimelineView.swift:1732 | `NSColor.systemOrange` (ripple) | `warning` |
| E/TimelineView.swift:1763, 1803 | `label3` alpha .08 / .06 | `fill2` |
| E/TimelineView.swift:1772, 1806 | `systemFont(10)`, `label3` alpha .6 | `caption`, `label3` |
| E/TimelineView.swift:1766, 1804, 1832-1834 | radius 3 literal | `Radius.small` |
| E/TimelineView.swift:1831 | clip color alpha .55 | `clipGhost` |
| E/TimelineView+SpeedBand.swift:127-138, 152-153, 171, 184 | 9 `Theme.white/black(α)` literals | `clipBadgeFill/Edge`, `onClip` |
| E/TimelineView+SpeedBand.swift:141 | systemFont 9 medium | `captionStrong` |
| E/TimelineView+SpeedBand.swift:180 | systemFont 11 semibold | `bodyStrong` |
| E/TimelineView+Keystones.swift:125-139 | accent .55, white .9, radius 3 / 1, 9 medium font | `accentTint`, `onClip`, `small`, `captionStrong` |
| E/TimelineView+Transitions.swift:132-141 | radius 2, black .34, white .55/.7/.9 | `small`, `clipShade`, `onClip`/`label2` |
| E/TimelineView+SilencePreview.swift:9 | red alpha .28 / .9 | `dangerTint` / `red` tokens |
| E/TimelineView+DuckCurve.swift:39-41 | black .45, warning .9 | `clipBadgeEdge`, `warning` |
| E/ClipDrawing.swift:43 | `hex(0x6B2A26)` | `offlineClip` |
| E/ClipDrawing.swift:359, 394-399, 414-416, 430-434 | 10 `Theme.white/black(α)` literals | `clipBadge*`, `onClip`, `clipShade` |
| E/ClipDrawing.swift:371 | mono 9 semibold, `NSColor.white` | `captionStrong`, `onClip` |
| E/ClipDrawing.swift:378 | `NSColor(srgb .86,.2,.2)` | `red` |
| E/FXBadge.swift:42, 52-57 | `CGColor(1,1,1,.85)`, white/black α | `clipBadge*` |
| E/KeyLanes.swift:74 | `lane.withAlpha(.55)` | token `laneDim` |
| E/RulerView.swift:104, 146-152 | accent .6; 7 marker colors as srgb literals | `accentTint`; `Palette.marker` |
| E/TrackHeaderView.swift:124, 166 | symbol pointSize 10, button 16 | symbol 9 or 11; `Metrics` token |
| E/TimelineGeometry.swift:54-55 | caption row 22, ghost row 24 | `trackOther` 20, 20 |
**Migration status 2.3: DONE** except (kept to keep the decided look): waveform white .55 (not `clipAudioWave`, a color change), `KeyLanes` lane .55 (no `laneDim` token), `RulerView` cache strip accent .6 (`accentTint` is .22), SilencePreview (already `red` derived, no `dangerTint` token), `TimelineGeometry` caption 22 / ghost 24 rows and TrackHeader button 16 (size changes).

(also `Theme.Fonts.clip` 9.5 and `meter` 9 → `caption` 10; `WaveformTileCache.swift:40` white .55 → `clipAudioWave`.)

### 2.4 Monitors / viewer overlays (14) - MIGRATED
| Where | Uses | Should |
|---|---|---|
| E/MonitorPanelView.swift:70 | `monospacedSystemFont(10)` (fully mono) | `caption` |
| E/MonitorPanelView.swift:174-175 | button padding 5, boxHeight 22 | padding token, `control` 20 |
| E/MonitorPanelView.swift:365 | drop border `controlAccentColor` 2 px | drop-target token (1 px `accentRing` + tint) |
| E/MonitorPanelView.swift:521-526 | icon button 22x18 | `toolButton` / `control` |
| Theme `monitorStrip` 44, `monitorSliderMaxWidth` 80, `monitorSliderHeight` 14, `monitorDimWidth` 22, `monitorDimHeight` 18 | listening level strip under the audio meter (F7.5) | tokens |
| Theme `monitorHeader` 34 | 34 vs footer 32 | 32 |
| E/MonitorScrubBar.swift:98-103 | radius 1.5, accent .7 | `small`, `accent` |
| E/MonitorScrubBar.swift:123 | black .5 knob edge | `onPictureShadow` |
| E/ProgramSurfaceView.swift:285, 335-338 | accent .5 selection, black .8 bg, white/clear | `accentTint`, `hudFill`, `onPicture` |
| E/ProgramSurfaceView.swift:460-462 | black .5 / white strokes | `onPictureShadow` / `onPicture` |
| E/TransformOverlayView.swift:276-388 | 14 white/black stroke literals, widths 1-3.5 | `onPicture` / `onPictureShadow`, 2 widths |
| E/TransformOverlayView.swift:359 | `guideColor` srgb(1,.25,.62) | `guideSnap` |
| E/Graphics/GraphicsOverlayView.swift:129-149 | white .25 / white | `onPicture` |
| E/TrimMonitorView.swift:153 | `Radius.card` 6 | `overlay` 8 |
| E/ScopeRenderer.swift:12, ScopesView.swift:23/52/57 | `MTLClearColor(12/255)`, white .16/.30, yellow .55 | derive from `viewer`; `Palette.scope` |

### 2.5 Effect Controls / keyframes / graph (16) - DONE (phase 2 migration)
| Where | Uses | Should |
|---|---|---|
| E/EffectControlsView.swift:406 | `Fonts.sectionTitle` 12 semibold (Theme extension outside Theme.swift) | `bodyStrong` in Theme |
| E/EffectControlsView.swift:408 | `Fonts.groupTitle` 10 semibold | `captionStrong` |
| E/EffectControlsView.swift:259, 264, 590, 602-603 | x 8 / 12 / 28 / 124 literals | indent ladder 8 / 28 / 104 |
| E/EffectControlsColorRows.swift:40-41, 82, 131, 187 | property indent x 36 | 28 (same as other rows) |
| E/EffectControlsColorRows.swift:134, 186 | label h 13, field 20x78 | 14 label, `control` |
| E/EffectControlsColorRows.swift:81 | dots row 26 | 24 |
| E/ScrubField.swift:99 | radius `field` 4 | `control` 5 (SQTextField already 5) |
| E/ScrubField.swift:103 | focus ring 2 px | 1 px |
| E/ScrubField.swift:46 | `.black` value text on curve tint | `onAccent`-style token |
| E/GraphEditorView.swift:25-34 | 13 curve colors as hex | `Palette.graphCurve` |
| E/GraphEditorView.swift:192-197, 216-222 | white fills, black text, `hex(0xFFF7B0)` tooltip, radius 2 | tokens; tooltip = `overlay` + `label` |
| E/GraphEditorView.swift:419-420, 439 | black strokes, radius 4 | `onPictureShadow`, `control` |
| E/KeyframeToggleView.swift:70, 87 | white / black | `label` / `clipBadgeEdge` |
| E/EasingThumbnail.swift:50 | black stroke | token |
| E/CompressorBandsView.swift:91 | accent .55 × α | `accentTint` |
| E/LoudnessMeterView.swift:115, 151, 195 | row 14 / gap 6, yellow .8 | tokens, `yellow` |

### 2.6 Project / Effects / Library panels (15) - MIGRATED
| Where | Uses | Should |
|---|---|---|
| E/ProjectPanelView.swift:161 | list row 22 | `listRow` 24 |
| E/Library/LibraryPanelView.swift:111 | sidebar row 22 | 24 |
| E/TemplateListPanelView.swift:199, 203 | header 22 / items 28 | 24 / 24 |
| E/CaptionsTabView.swift:56, KeystonesPanelView.swift:32 | `mediaRow` 28 (no thumbnail) | `listRow` 24 |
| E/Library/LibraryPanelView.swift:583 | grid selected `accentTint` | per state table (selection / accentTint when focused), same as list |
| E/ProjectIconView.swift:66-67 | selected `accentTint`, radius `small` 2, inset 1 | `control` 5, same state token |
| E/Library/LibraryPanelView.swift:549 | tile radius `row` 3 | `control` 5 |
| E/TextStyleGridView.swift:91-133 | radius 4, white .06 hover, `NSColor(white:.78/.16)` | `control`, `rowHover`, `label`/`content` |
| E/ProjectIconView.swift:31-32 | badge black .6, radius 2 | `hudFill`, `small` |
| E/ProjectPanelView.swift:22, 62 | radius 2 / 2.5 | `small` |
| E/ProjectPanelView.swift:346 | constant 5 | `iconToLabel` 6 |
| E/ProjectPanelView.swift:547 | popup 24 | `control` 20 (in panel) |
| E/Library/LibraryPanelView.swift:126, 150, 163-164 | insets 4/8, chip spacing 4, grid gap 8 | panel inset 12/8 tokens |
| E/Library/LibraryPanelView.swift:567-575, 647-650 | constants 4 / 2, icon 36x22 | spacing tokens, thumbnail metric |
| E/TemplateListPanelView.swift:111, 189 | hint h 18, icon 18 | tokens |

### 2.7 Inspectors: Text / Graphics / Captions / Clip sections / Transitions (17) - DONE (phase 2 migration)
| Where | Uses | Should |
|---|---|---|
| E/TextPanelControls.swift:8 | row 20 | `propertyRow` 24 |
| E/TextPanelControls.swift:179-215 | own flat popup (duplicate of SQPopup), font 11 literal | `SQPopup` |
| E/TextPanelControls.swift:136 | 10.5 medium | `captionStrong` |
| E/TextPanelControls.swift:229 | menu font 11 | menus use `title` 13 |
| E/TextPanelControls.swift:300, 320 | title 12 semibold, header 28 | `bodyStrong`, section row 24 |
| E/TextPanelControls.swift:321, 333 | indent 12, insets 8/12, spacing 6 | panel inset tokens, 8 |
| E/TextPanelControls.swift:29, 63, 66, 126 | white, radius 3 / 4, panel .55 disabled | `label`, `small` / `control`, `disabledAlpha` |
| E/TextInspectorView.swift:20 | native `NSButton("All Styles")` | `SQButton` |
| E/TextInspectorView.swift:157, 348 | `systemFont(11)` | `body` |
| E/TextInspectorView.swift:291, 297 | insets 10/12, spacing 1 | 8/12, 0 or 2 |
| E/ClipSectionsView.swift:145 | 11 semibold | `bodyStrong` |
| E/ClipSectionsView.swift:242-243 | x 8 / 24 | indent ladder |
| E/CaptionsPanelView.swift:20, 63 | native `NSProgressIndicator` | own progress bar (export dialog style) |
| E/CaptionsPanelView.swift:211-222 | label .16, yellow .35, `hex(0x000000)` | `selection`, `yellowTint`, `onAccent` |
| E/CaptionStyleTabView.swift:97-98, 301-302 | swatch 34x20 | swatch 38x20 |
| E/Graphics/GraphicsPanelView.swift:43, 385, 532-533 | insets 8/10/12, spacing 4/6 | panel inset tokens |
| E/Graphics/GraphicsPanelView.swift:406-407, 513-517 | swatch 40x20, row 22, radius 4 | swatch 38x20, 24, `control` |
(also E/TransitionControls.swift:391 field 24 → `control` 20.)

### 2.8 Color page (13) - MIGRATED
| Where | Uses | Should |
|---|---|---|
| E/Color/ColorControls.swift:271 (`sectionTitle` 12) vs ColorInspectorView.swift:192 (`bodyTitle` 13) | two section-title fonts on one page | `bodyStrong` |
| E/Color/ColorInspectorView.swift:209 | section row `panelHeader + 2` = 30 | section row 24 |
| E/Color/ColorInspectorView.swift:206 | insets 12 literal | `Spacing.md` |
| E/Color/ColorInspectorView.swift:631 | `NSColor.systemBlue` | `Palette.graphCurve` blue |
| E/Color/ColorInspectorView.swift:640-641, 676 | swatch 36x20, radius 2 | 38x20, `small` |
| E/Color/ColorControls.swift:58-65 | white-balance gradient hex | `Palette.whiteBalance` |
| E/Color/ColorControls.swift:86 | white .72 / .30 | `label2` / `label3` |
| E/Color/ColorControls.swift:359 | 4 swatch colors hex | palette token |
| E/Color/ColorControls.swift:423, 445 | black .45, radius 3 | `hudFill`, `small` |
| E/Color/ColorControls.swift:287 | left 12 literal next to `Spacing.md` | `Spacing.md` |
| E/Color/ColorWheelControl.swift:82-146 | 9 `Theme.white/black(α)` literals | `fieldEdge`, `label`, `onPictureShadow` |
| E/Color/ColorWheelControl.swift:109-121 | radius 2 / 4 | `small` / `control` |
| E/Color/ColorCurveEditor.swift:115, 133-135; ColorClipStripView.swift:202 | white .2/.92, black .5, radius 2 | tokens, `small` |

### 2.9 Dialogs / sheets / windows [migrated, Phase 2] (24)
| Where | Uses | Should |
|---|---|---|
| E/SQDialog.swift:157-158 | button padding 14, height 24 | `controlLarge` 24 + padding token (same in A/RelinkSheet.swift:46) |
| E/SQDialog.swift:195, 208 | field 22 | `controlLarge` 24 |
| E/SQDialog.swift:383 | field radius `field` 4 | `control` 5 |
| E/SQColorPicker.swift:94, 279 | checker `NSColor(white:.30/.45)` | `Palette.checker` |
| E/SQColorPicker.swift:102-119 | white/black gradients + knob strokes | `onPicture`/`onPictureShadow` |
| E/SQColorPicker.swift:183 | pad 10 | 8 / 12 |
| E/SQColorPicker.swift:189, 194, 201 | radius `field` 4, hex field `body` 13 | `control` 5, `body` 11 |
| E/SQSlider.swift:65-68 | radius 1, `NSColor.white` thumb, alpha .45 | `small`, `label`, `disabledAlpha` |
| E/SQButton.swift:130 | accent text `.white` / white .5 | `onAccent`, `disabledAlpha` |
| E/SQFlatButtonStyle.swift:11, 27 | `.system(size: 11)` | `Quiet.font` (= `body`) |
| E/SQFlatButtonStyle.swift:16 | pressed `accentFill.withAlpha(.8)` | `accentFill` (as SQButton) |
| E/RemoveSilencesDialog.swift:108-120 | `NSFont.systemFontSize` 13 / `smallSystemFontSize` 11 | `body` / `bodyStrong` |
| E/TrackMixDialog.swift:14 | `smallSystemFontSize` | `body` |
| E/SpeedDurationSheet.swift:76-92; PasteAttributesDialog.swift:20 | spacing 6 / 14 | 8 / 12 / 16 |
| A/AppController+CutCheck.swift:12-28 | `secondaryLabelColor`, `labelColor`, `separatorColor`, `controlAccentColor`, radius 2 | Theme colors, `small` |
| A/AppController+CutCheck.swift:12-14, 57-63 | fonts 10, 12, mono 12, 11 semibold | `caption`, `body`, `bodyStrong` |
| A/AppController+PunchInCuts.swift:23, 25-29 | font 12, spacing 10 | `body`, 8 / 12 |
| A/ImportReportSheet.swift:49-85 | spacing 1/6/8/10, insets 8/10/16 | 16 padding, 12 gap, 8 |
| A/KeyboardShortcutsWindow.swift:93-112 | constants 4/6/8/10/12 | grid tokens |
| E/KeyboardLayoutView.swift:148-157 | 10 group colors srgb literals | `Palette.shortcutGroup` |
| E/KeyboardLayoutView.swift:172-195 | `controlAccentColor` stroke, white α, fonts 8/9/11 medium | `accent`, `label*`, `caption`/`captionStrong` |
| A/NewProjectSheet.swift:18-22; AppController+Start.swift:123-124; AppController+LiveDucking.swift:10; FrameExport.swift:26 | popups/fields 22 / 24 / 26 | `controlLarge` 24 |
| A/QuietSwiftUI.swift:8, 44 | row 28, hover = `selection` | `listRow` 24, `rowHover` |
| A/StartWindow.swift:104, 126; CardImportWindow.swift:330, 347 | radius row 3 / card 6 / clip 3 | `small` rows, `overlay` cards, `control` tiles |
(also E/StartupSplash.swift:121 pad 22 → 24; A/SettingsWindow.swift:61 constant 40.)

### 2.10 Export (12) - MIGRATED
| Where | Uses | Should |
|---|---|---|
| E/Export/ExportQueueView.swift:16, 40 | SwiftUI `List` + `ProgressView` (system look) | Quiet list + own progress bar |
| E/Export/ExportQueueView.swift:13, 42-46, 67, 71 | `.font(.caption)`, `.foregroundStyle(.secondary)` | `Quiet.fontMini`, `label2` |
| E/Export/ExportDialogView.swift:421 | settings row 28 | `propertyRow` 24 |
| E/Export/ExportDialogView.swift:230, 252 | list rows 26 / 24 | `listRow` 24 |
| E/Export/ExportDialogView.swift:95, 106-125 | controls 22 / 24 high, x 34/184/190 literals | `controlLarge` 24, grid |
| E/Export/ExportDialogView.swift:74, 80, 114, 121, 154, 162 | label heights 16 / 18 | text metrics from font |
| E/Export/ExportDialogView.swift:449, 517 | x 12, 10x16 | tokens |
| E/Export/ExportDialogControls.swift:70 | row 22 | 24 |
| E/Export/ExportDialogControls.swift:107 | selected text `NSColor.white` | `label` |
| E/Export/ExportDialogControls.swift:157, 173 | x 12, inset 7 | 12 token, 8 |
| E/Export/ExportDialogControls.swift:189-194 | radius 2, `NSColor.white` knob | `small`, `label` |
| A/MainWindow.swift:44 (status ring, counted in 2.2) | — | — |

### Totals
Menus/popovers 14 · panel chrome 9 · timeline 22 · monitors 14 · Effect Controls 16 · Project/Effects/Library 15 ·
inspectors 17 · color 13 · dialogs/windows 24 · export 12 = **156 rows** (~300 literal sites).

### Top inconsistencies
1. **Row heights**: list rows 22 (Project, Library sidebar) vs 28 (Effects, Captions, Keystones, Quick Apply, settings, SwiftUI)
   vs 24 (menus, Effect Controls) vs 20 (Text panel) vs 26/28 (Export). → 24 everywhere, 28 only with a thumbnail.
2. **Type scale**: 11 sizes in use (8, 9, 9.5, 10, 10.5, 11, 11.5, 12, 12.5, 13, 18) and 4 weights; section titles alone
   come in 13/12/11/10.5/10 semibold; menus are 12.5 while dialogs are 13. 30+ fonts built outside Theme.
3. **Radii for the same role**: fields 4 (ScrubField, dialog, hex) vs 5 (SQTextField, search); tiles 2/3/4/6
   (Project grid, Library grid, Text styles, card import); Quick Apply / trim card 6 vs floating 8; menu highlight 4 inside 8.
4. **Selection / hover**: lists `selection` white .10, grids `accentTint`, Quick Apply full `accent`, menus `overlayHover`,
   SwiftUI hover `selection`, Library media table system blue; focus ring 1 px vs 2 px; system `controlAccentColor`
   in monitor drop, keyboard layout, Cut Check.
5. **Literal colors in custom drawing**: ~120 `NSColor.white/black`, `Theme.white/black(α)`, hex/srgb literals
   (timeline badges, transform overlay, graph editor, color wheels, marker and shortcut palettes); plus native
   leftovers (NSProgressIndicator x2, SwiftUI List/ProgressView, NSButton "All Styles", SQMenuPopUpButton).

### Round 3 (2026-10-04): family-by-family consistency pass
- **Rows**: every list and property row now reads `Theme.Row` (24): Library/Project lists (was 22), Effects list,
  Shortcuts, Settings (was 28), Effect Controls popup rows, Text/Graphics/Captions rows, Color control rows, Export
  setting rows (were 28). 28 stays only for thumbnail rows (`Row.thumb`). Guarded by `ThemeTests.panelFamiliesShareOneRowPitch`.
- **Type**: `Theme.Fonts` is gone; everything reads `Theme.Typography` (10/11/13/18, Regular + Medium). 13 semibold
  became 13 medium; meter scale 9 became 10.
- **Floating layers**: one edge `Colors.overlayEdge` (white .14) at `Overlay.edgeWidth` 0.5 for menus, popovers,
  tooltips, dialog forms; menu highlight radius `Radius.control`.
- **Fields**: hover edge `Colors.fieldEdgeHover` shared by SQTextField, SQSearchField, ScrubField.
- **Timeline chrome**: track/ruler lines and playhead read `Colors.trackRowLine/trackHeaderLine/rulerLine/rulerMinor/playhead`.
- **Removed**: `Theme.Fonts`, `Metrics.listRow/effectsRow/controlHeight/effectControlsRow`, `Theme.Fonts.sectionTitle`.
- **Remaining outliers (kept on purpose)**: dialog card radius 14, dialog form rows 28 / buttons 26 (board); timeline
  mix/caption rows 22; waveform/key-lane white .55; in/out tints; black/white contrast strokes on picture; native-control
  lint hits (NSMenu as model for SQ menus); `Theme.Metrics` vs `Theme.Row` duplicates (panelHeader, topBar).
- **Open (visual, not tokens)**: Graphics panel field style (boxed) vs Effect Controls (plain); layer-row icon columns
  unaligned; Color page monitor header shows a second row with a duplicate "…" button; ClipSectionsView own chevron
  instead of DisclosureGlyph.
