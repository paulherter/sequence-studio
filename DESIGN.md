# Sequence Studio design (short form)

Source of truth: the design artifact (v11) and its boards in `build/design-boards/` (HTML in `html/`), values in
`docs/design-source/sq.css`. Code reads values only through `Theme` / `ThemeTokens` and SQ components.
Token API: `docs/DESIGN-SYSTEM.md`. Where this file and a board differ, the board wins.

## Tokens (sq.css var -> `Theme.Colors`)
| Role | Value | Token |
|---|---|---|
| Bar (top bar, panel headers) | #232326 | `titlebar` |
| Support heart and its filled button (Support entries only) | #EA4AAA | `Colors.support` |
| Panel body | #1e1e21 | `panel` |
| Content (lists, wells, key canvases) | #19191c | `content` |
| Timeline / lane | #151518 / #18181b | `timeline` / `lane` |
| Layer (menus, popovers, dialogs) | #2a2a2e | `overlay` |
| Picture surround (Program, Source, Color viewer; Metal clear color `Presenter.surround` equals it) | #2c2c2c | `monitorBackdrop` (1.5:1 over the picture's black) |
| Scopes / export preview backdrop | #0c0c0c | `viewer` |
| Gap between panel cards and around the workspace (2 pt; cards have 3 pt radius, no divider line under the top bar) | #080809 (never pure black) | `divider` |
| Hairline | white 6.5 % | `separator` |
| Text 1 / 2 / 3 | #e6e6e8 / #b2b2b8 / #9c9ca2 (opaque) | `label` `label2` `label3` |
| Fill / fill2 / hover / pressed | white 11 / 6 / 16 / 22 % | `fill` `fill2` `fillHover` `fillPressed` |
| Field / edge | black 28 % / white 10 % | `field` `fieldEdge` |
| Selection (gray pill, list row) | white 14 % | `selection` |
| Accent / primary fill / tint | #A56BFF dark, #7A33E0 light / #7C3AED / accent 22 % (P3 Violett, 2026-10-13) | `accent` `accentFill` `accentTint` |
| Selected keyframe, In/Out | accent | `keyframeSelected` `inOutTint` `inOutEdge` |
| Tracked frame of a Magic mask (lanes: 60 % key size; selected = accent) | text 3 | `keyframeTracked` |
| In/Out wash, track row line | white 6 %, 9 % (header 12 %) | `inOutWash` `trackRowLine` `trackHeaderLine` |
| Playhead K1 | line 2 pt `playhead` (white 92 %); head 12 x 12, icon head shape, porcelain gradient #FFFFFF to #C3C9D9, dark hairline in light | `playhead` `PlayheadSkin` |
| Icon gradient (export progress, finished) | #350670, #8727C7, #EF3A87, #FE9E46 | `IconGradient.stops` |
| Yellow / orange / red | #ffd60a / #ff9f0a / #ff453a | `yellow` (clips, tiles, snap) `marker` `red` |

Color roles: blue fill = the one primary button and checked boxes; gray pill or blue tint = selected option; menu highlight
gray; yellow = selected clips, tiles, snap line; selected keyframes = accent; orange = markers/warnings; red = errors/offline.
Clip colors are unchanged (`clipVideo` ...).
Project panel item types wear exactly the colors of their timeline clips: one source, `LabelColor` (SQCore) resolved through
`Project.clipLabels(of:)` (same rules as `LabelResolver`, so user labels apply to both). Defaults, a bit poppier than before:
video blue `#2f6fb0`, audio green `#1e8449`, video with audio both (split chip / two-tone icon), photo violet `#9a50c8`,
folder pink `#bc4f78`, sequence forest `#3f7a4a`, nested sequence `#4f78a3`, title `#7350c0`. All keep white clip text at >= 4.5:1.
`Theme.Colors.clip*` derive from `LabelColor`; there is no `clipStill`. Tests pin panel color == timeline color for every kind.
Project list rows show the kind as a 16 pt chip (radius `Radius.small`) in the item's color (video with audio: two halves; offline: red) with the kind's `SQIcon` (11 pt, 1.6 stroke) in `LabelColor.onFill`, so the kind reads without the color. Row height and text baseline unchanged.
Icons: video `film`; audio `waveform`; video+audio `film` on a two-tone chip; photo `image`; folder `folder`; sequence `sequence`;
nested sequence `stack`; title `text`; generator `generator`.
Timeline sequence tabs: the open sequence's underline is always `accent`; the panel's focus line (`PanelActiveMarker`) stays the app-wide focus marker.
Tools that only act in the monitor (Create/Text, shapes, Pen, Mask) behave as Selection inside the timeline (`TimelineTool.effectiveTimelineTool`); the active tool does not change.

## Shape rules
- Buttons, popups, segments and single-line fields (scrub field, search, text): capsule, 22 high, radius 11 (`Metrics.capsule`).
- Multi-line boxes, lists, wells: radius 8 (`Radius.well`). Checkbox 14 px, radius 4 (`Radius.checkbox`).
- Slider: 2 px track, 10 px knob (`Metrics.sliderTrack`, `sliderKnob`), accent filled part, arrow cursor always.
- Popup: one down chevron (7 x 10, gray). Scrub / number values: accent text.
- States: default, hover (fill .16, fields white .18 edge), pressed (.22), selected, disabled (opacity .4),
  keyboard focus = inner 1.5 px accent line (`State.focusLine`, `ControlShape.drawFocusLine`).
- A control sits centered in its row; a row of buttons has 8 px above and below; every clickable part is at least 22 x 22 pt.
- One disclosure: `InspectorSection` (whole 24 pt row is the hit area, drawn chevron, 120 ms).

## Components (SQEditorUI)
`SQSegmented` with icons (Simple | Pro grade switch on the Color page, windows plan section 7, variant B): `images` plus `showsIconBesideLabel` draws a 14 pt icon 6 pt left of the label (wand = `SQIcon.toolMask` for Simple, `slidersHorizontal` for Pro), 76 pt segments, tooltip per segment. `acceptsKeyboard` (opt-in) gives Tab focus with the focus line and Left/Right to select. Icons only on this switch; every other two-word switch stays text.
`SQButton` (standard / accent / icon), `IconButton`, `SQPopup`, `SQSegmented`, `SQCheckbox`, `SQSearchField`, `ScrubField`,
`SQSlider`, `NumericSlider`, `InspectorSection` (+ `InspectorSectionHeader`, `InspectorRow`), `EmptyStateView`,
`KeyframeControls`. Shared drawing helper: `ControlShape` (capsule, focus line).
`SQToast` (SQUIKit, so inspector packages can raise it): a 40 pt message floating at the bottom center of the window, 44 pt
above the edge, max 70% wide, overlay surface and edge, 12 pt text, optional ghost "Undo" button; fades in, stays 4.2 s,
one per window. `SQToast.show(text, undo:, in: view)`. Used for the Color page messages (Graph added, copied from Simple).

Controls column (text concept B, Bild 5): ONE skeleton for every selection, sections absent when they do not apply, never
reordered: header (clip name, kind) · Text / Shape / Template / Graphic (content; for text one Text section that ends with the Look and the
Look row, Update / Save as New and fill, outline, background, shadow: no Appearance header) · Transform (a text clip's Box and Arrange
rows are its last rows) · Animation (Intro and Outro popups: Off first, then the neutral Fade / Rise / Scale In and
Fade Out / Slide Out / Scale Out, the other presets, the saved ones, "Custom", and "Save Custom…" while the side is
Custom; a Custom side adds the section "Intro Animation" / "Outro Animation" right below with the rows Position, Scale,
Rotation, Opacity: the same Controls rows as Transform, each with its lane and opening inline to its speed curve; only
a Custom side has rows, a preset is never edited through Controls; after "Save Custom…" the side plays the saved
animation and the popup shows its name, "Custom" makes it editable again; a saved animation keeps its name in every
sequence format; one that was deleted from the Library keeps playing and the popup shows "Saved" with no entry checked;
a save that fails shows a notice in the status line; a looping side keeps looping after the save, the saved animation
itself plays once where it is picked later; when several animations hold the same curves the popup shows the one picked
or saved last; the Graphics panel's text item has the same popups with the same saved animations) ·
Speed · Mask · each applied effect · Audio; with a caption selected, or no clip
selected and a caption track in the sequence, the last section is "All Captions" instead: the one read-only caption
list (`CaptionReadListView`, time on the label column, text from the control column to the trailing inset, the caption
at the playhead marked, a click seeks; it scrolls inside the column's height). Every row sits on `ControlsGrid`
(docs/DESIGN-SYSTEM.md, Controls grid). Components: `ControlsGrid`, `TextBlockRow` + `GridStack`, `AppearanceHead` /
`AppearanceRow`, `ControlsRows` (stack helpers for a section's rows), `CaptionReadListView`. The Look menu is the same
in every host (Controls, Captions > Look, Graphics): Update, Save as New Look… (asks for the name), Rename…, Delete
(`TextBlockView.lookMenuItems`).
Section headers are `SectionHeaderRow` (keyframable sections) or `InspectorSectionHeader` (everything else), same height
and columns.

Timeline skin values (clip edge white 22 %, thumbnail rule black 35 %, waveform white 55 %, In/Out wash white 13 % with 38 % edges, ruler cache strip, fx pill, item bar, silence and duck tints) live in `Theme.TimelineSkin`; timeline drawing has no alpha literals of its own.
Timeline tool icons: all are `SQIcon` glyphs (blade `toolBlade`, hand `toolHand`; slip, slide, ripple, roll and rate stretch are our own drawings), 14 pt. Empty track lanes stay `lane` (#18181b).
Timeline clips are ONE color: the label / type fill covers the whole clip (no darker body under a name bar). The name sits in the top 13 pt band in `LabelColor.onFill` (white, or black on light fills, >= 4.5:1); thumbnails and waveforms are drawn over the fill below it. The fx badge never overlaps the name: the name truncates before it (`ClipDrawing.fxBadgeReserve`).

Icon buttons have no fill at rest, hover or selected (States board): hover brightens the glyph to `label`, selected is the accent glyph, pressed keeps the `pressed` fill. Every `SQButton`/`IconButton`/timeline tool button routes `toolTip =` and `setTooltip` to `SQTooltip` (never the system tip); the tip shows after 0.8 s, and for 0.5 s after one closed by leaving its button the neighbor shows at once (`SQTooltipLayout.showDelay`). Tooltips (`SQTooltip`) have no outer shadow; a trailing "(key)" draws as a keycap chip (sq.css `.kc`). The monitor footer drops the stream handles, then the duration, when narrower than its content (min 320).
Open: translucent label colors measure brighter than opaque ones in `cacheDisplay` (peak 211 vs 162 for white 52 %); cause not established as offscreen-only, so no token change.

## Program monitor: Magic mask clicks (SQEditorUI, MagicClickMode.swift)
- Magic mode shows `SQSegmented` "Add | Remove" (64 pt segments) top left of the picture area (inset `Spacing.sm`); Option flips the shown segment while held. Click points of the active mask on the shown frame draw as 5 pt dots with a white + / -, fill `OnPicture.magicAdd` (green) / `OnPicture.magicRemove` (red), 1 pt `OnPicture.shadow` edge.
- Program menu, under "Mask Tint": "Subject Mask Edges" with the submenu "Quality" / "Speed" (`SubjectMaskQualityMenu`, plain `SQMenuItem` rows, the stored choice checked, one help line each). A choice shows one status line; it holds for this Mac (`sq.subjectMask.quality`), not the project, and applies from the next Track.

## Program monitor: no Look strip
- The Program monitor shows only the preview, its badges and overlays, and on-canvas creation and moving of text. It carries no Look tiles and no style controls (removed 2026-10-12; Looks were a strip docked beside or under the picture).
- Text Looks live in Controls: the Look popup (name, "edited", Update / Save as New) at the end of the Text section, and the Looks gallery in the text block and the Captions Look tab.

## Program monitor: text states (SQEditorUI, MonitorTextInteraction.swift)
Pure table (tool + pointer target + editing -> cursor, frame, action); `ProgramSurfaceView` and `EditorPanels` only apply it. Tests: `MonitorTextInteractionTests`.

| Tool | Pointer over | Cursor | Frame + handles | Click | Double-click | Esc / click outside |
|---|---|---|---|---|---|---|
| Type | empty canvas | I-beam | on the selected text layer, drawn only (inert) | creates a text layer there, enters editing (all selected) | same | ends editing, layer stays selected |
| Type | text layer | I-beam | as above | selects it, enters editing, caret at the click | same | as above |
| Type, editing | anywhere | I-beam (system I-beam in the field) | visible, inert | click outside the field ends editing, then the rule above | n/a | ends editing, layer stays selected |
| Select | selected text layer | move (resize / rotate on handles) | visible, draggable | drags | enters editing | n/a |
| Select | unselected text layer | arrow | none | selects it (topmost under the pointer) | selects it | n/a |
| Select | empty canvas | arrow | unchanged | selects the clip under the pointer, if any | n/a | n/a |
| Select, editing | anywhere | system I-beam in the field | visible, inert | click outside ends editing | ends editing | ends editing, layer stays selected |
| Hand | anywhere | open hand | hidden | pans | fit | n/a |
| Create: Rectangle, Ellipse, Line, Draw | anywhere on the picture | crosshair | frames of the Graphic the item goes into, drawn only | nothing (a drag makes the item; ends a running text edit) | n/a | Escape cancels the running drag |

## Create tool (SQEditorUI: ToolState.swift, ToolStripView.swift, CreateToolDrag.swift; App: EditorPanels+CreateTool.swift)
One slot in the tool strip (the former Text slot), long-press menu like the Mask slot: Text (default), Rectangle, Ellipse, Line, Draw; `SQIcon` glyphs, 14 pt. Tooltip "Create: Rectangle (key) (hold for Text, Ellipse, Line, Draw)". Keys: T Text, Option+Shift+R / E / L / D for the shape modes.
- Drag on the Program monitor makes one item of a Graphic clip: into the selected Graphic under the playhead, else the Graphic under the playhead on the topmost targeted video track, else a new Graphic clip at the playhead (first free video track, default text length). One undo step per item. A press without a drag (under 6 pt) makes nothing.
- Shift: square, circle, line in 45 degree steps. Option: grows from the press point. Escape: cancels the drag.
- Preview (`CreateToolPreviewView`, drawn only): the outline in `OnPicture.stroke` 1.5 pt over `OnPicture.shadow` 3 pt; under it a size pill (`OnPicture.hudFill`, `Radius.small`, caption medium, `Spacing.sm` below the outline, `Spacing.xs` inner pad) with the size in sequence pixels ("96 × 96", a line shows its length, Draw shows none).
- Draw: the stroke is smoothed and reduced (`PathSmoothing`, tolerance 1.5 view points) before it becomes a path item.
- No Fill/Outline bar over the picture: the look of an item is set in Controls only.

With a graphics clip selected (playhead inside it) the same table applies to its layers (`inGraphic`, `GraphicsOverlayView`): Type click on a text layer edits it, a click elsewhere adds a text layer centered there and types at once (an empty new layer leaves no undo trace; add + typing = one "Add Text" step; editing an existing layer = one step); a Type drag counts as a click at its center. Select: double-click a text layer edits it; the move cursor shows only over the selected layer; with Type or a text field open the layer frame is drawn only. Layer moves snap their box edges and center, resizes their dragged corner, to the frame edges, center and the title / action safe margins (`GraphicsSnap`, accent guide lines); Shift or Option disables a move's snapping, Option a resize's (Shift keeps the aspect there). No snapping while the graphic is rotated.

Caret is the on-picture stroke color, selection `accentTint`. Overlay handles never set a cursor unless interactive (`TransformOverlayView.isInteractive`).

## Timeline: item lanes of an opened Graphic (SQEditorUI: TimelineView+ItemLanes.swift; App: EditorPanels+ItemLanes.swift)
A Graphic clip with more than one item shows a disclosure arrow at its head, in front of the name (`chevron.right` closed, `chevron.down` opened, 12 pt box, after the thumbnail and clear of both trim handles, the name moves right by its width; hidden when the clip is too narrow). The arrow reacts to the Select tool only: every other tool does its own work there, and a press on a trim handle always trims the clip. A click opens the clip: under its track row one lane per item appears, top item first, and the tracks below move down. One Graphic per track is open at a time; opened is view state (not saved, not undoable) and closes by itself when the clip is gone or has one item left.
- Lane: height `Metrics.trackOther`, no gap between lanes. In the header column the item's type icon (same `SQIcon` glyphs as the Layers list) and its name (`Typography.body`, one line, truncated), `Spacing.iconToLabel` between them; a selected item uses the primary text color, the others the secondary.
- Bar: the item's range inside the clip, inset `Spacing.xxs` top and bottom, `Radius.small`, filled with the accent at 45 % (selected: full accent with a 1 pt on-accent outline). An item clamped to nothing by a clip trim shows a 4 pt stub at that clip edge that can be trimmed out again.
- Gestures (Select tool, unlocked track): drag the bar to move it, drag an end to trim it; both stay inside the clip, a trim keeps one frame. Snapping as everywhere in the timeline (magnet, inverted by the modifier): clip ends, playhead, markers, the ranges of the other items, else the frame grid; the yellow snap line shows the hit. One undo step per gesture ("Item Range"); Escape puts the range back. An item that fills the clip can only be trimmed. A locked item (and every item on a locked track) is selected by a press but neither moves nor trims, as in the monitor.
- Range rules: a text item's In animation starts when the item appears and its Out animation ends when it disappears (the range, not the clip; keyframes stay on clip time). A cut drops the items that have nothing in a piece, but never all of them: a piece that would be left without items keeps them as stubs at that edge. Outside its range an item has no outline and no handles in the Program monitor (it stays selected).
- Monitor box: the box and handles of an item follow the range clock, the same one the picture is drawn with: inside the range they sit on the item as it looks at the playhead (its keyframes on clip time, a text's In and Out animation counted from the range's start and end), from the first frame of the range to its last. On every other frame of the clip they are hidden.
- Selection: a click on a bar or a lane name selects the item (Shift or Command toggles); the same selection as in the Program monitor, the Layers list and Controls, in both directions.
- Drawn with the clips into the timeline's content cache from prepared colors, icons and text lines: no allocation per frame.

## Right-column lists, version 9 (SQEditorUI: PanelListHeader.swift, TemplateListPanelView.swift; SQUIKit: EmptyStateView.swift)
- `PanelListHeader` / `PanelListHeaderCell`: column header of the Project list and the Library list. 26 high, 11 pt semibold `label3` on `panel`, 8 in (12 on the first column), hairline below, sort arrow next to the title.
- `FxBadge`: the "fx" mark in front of an effect row (16 high, radius 4, `fill`, 9 pt bold `label2`).
- `EmptyStateView.setAction(title:handler:)`: one standard button under the hint ("Import...", "Add Folder..."); the rest of the view stays click-through.
- Rows use `Theme.Row.panelList` (26) and `Theme.Typography.list` (12); selection and hover are rounded fills, no stripes.

## Library panel: sections and preview bar (SQEditorUI/Library)
- A Library folder with subfolders shows `LibrarySectionHeaderView` sections (24 pt row: chevron, name `body`/`label`, item count `caption`/`label3`, click toggles): first "All" (every item, recursive), then one section per subfolder, nested subfolders indented 12 pt per level, in grid and list. Collapsing a section hides its items and its nested sections. A folder without subfolders, Favorites and presets stay a plain list with no headers.
- `LibraryPreviewBar` sits at the bottom of the content column (hidden without a previewable selection): hairline, then video viewer 150 pt / photo 190 pt (`tileBackground`, control radius; audio has none), a one-line message (unplayable file, photo name), a scrub row (elapsed, `SQSlider`, total; `tabularBody`/`label3`), a control row (back 5 s, play/pause, forward 5 s | mute, 72 pt volume `SQSlider`). Icons are `IconButton` 12 pt. Video starts muted; selecting an item plays it (Space toggles while the Library has focus).
- Renders: `panel-library-sections-grid`, `panel-library-sections-list`, `panel-library-preview-audio` (scripts/render-panels.sh). The design-source boards (docs/design-source) have not been redrawn for this yet.

## Graphics panel: layer list (SQEditorUI/Graphics, LayerListView.swift)
- `LayerListView` is pinned at the top of the Graphics panel with its own scroll; the properties scroll below it. Between them a `ListResizeHandle` (1 px `SQDivider` hairline, 7 pt grab area, up/down cursor) sets the list height: at least 3 rows + footer, default 6 rows, kept under `sq.graphics.listHeight`.
- Rows are front first, 24 pt (`Row.list`). Layer row: kind icon (12 pt, `label2`) at 12 pt, name `body` / `label` (hidden layers in `label3`; an item outside its range at the playhead: name in `State.disabledText`, kind icon at `State.disabledAlpha`, lock and eye unchanged), then eye and lock `IconButton`s (eye first), 11 pt, in `iconSlot` slots at the trailing edge. The lock shows `lock.fill` in `label` when locked and `lock.open` in `label3` when unlocked.
- Group row: drawn chevron (`DisclosureGlyph`, click toggles; collapse is view state only), name in `bodyStrong`, and eye and lock for all members. Only rows in or next to the scroll window are placed and laid out (others hidden), so a panel resize costs the same for 5 and 60 layers. Return on the list: a text layer focuses its text box, another single layer renames its row. Members are indented by one icon column (34 pt).
- Fills:
  - selected: `Selection.fill` (`fillFocused` while the panel has the keyboard)
  - hover: `Selection.hover`
  - drop onto a group row: `accentTint`
- Insertion: a 2 pt `accent` line between rows.
- `KeyTickStrip` (Graphics/KeyTickStrip.swift): 4 pt strip at the bottom of a layer row, under the name (x from the name to the lock button). One 2 pt `accent` tick per key of the layer across the clip, a 1 pt `playhead` line; hidden when the layer has no keys and no range. An item with a range (item lanes) shows it there as a bar behind the ticks, in the fill of its lane bar (accent at 45 %, at least 2 pt wide). A click on it seeks (the list handles it; no selection change). No graph.
- Effects dropped from the Effects panel on a layer row: row fill `accentTint`, same as the group drop. Refusals show in a one-line status (`body`, `label2`) at the bottom of the panel for 3 s.
- Click selects; Shift selects a range, Cmd toggles; a group row selects all its members.
- Double-click renames in place with an `SQTextField` (Return commits, Esc cancels).
- Drag reorders. A drop between two members joins their group, anywhere else leaves it, and a dragged group never lands inside another.
- Right-click opens the `SQMenu`: Rename, Duplicate, Group, Ungroup | Bring to Front, Bring Forward, Send Backward, Send to Back | Delete.
- Footer, 32 pt, `panel` fill under a hairline: "+ Text" and "+ Shape" (an `SQMenu` of the shape kinds) `SQButton`s, the Draw `IconButton`, then Group, Duplicate and Delete at the trailing edge.
- Empty list: `EmptyStateView` "No layers yet".

## Graphics panel: properties (GraphicsPanelView.swift)
- Order: Arrange (6 align, 2 distribute `IconButton`s, "Align To" `SQSegmented` Frame | Selection), Transform, then by kind: Shape + Appearance (shape/path layers) or the shared text block (one text layer), then Effects.
- One grid for every section (Arrange, Transform, Follow, Text, Appearance, Animation, Effects): header 26 pt, sections touch (gap 0) with exactly one hairline per section (the header's top line, none inside), summary text in the header is `InspectorSectionHeader.makeSummaryLabel()`. Label column at `labelX` (88 wide), controls start at `valueX` and end at `controlColumnMaxX` (value 50, 3 fields + 2 gaps = 162); a wider panel leaves free room, never wider controls. Number fields are 50 wide, choosers (popup, segmented, slider) fill the 162; a `NumericSlider` in a row has its field first (`fieldLeading`), so all numbers start on `valueX`. Measured by `InspectorGridMeasureTests`. Text section: letter and line spacing share one row (the letter spacing icon is the label, its number starts on `valueX`, the line spacing icon + number follows one gap later); all other numbers (Size, font axes) start on `valueX` too.
- Several layers selected: equal values show, differing ones show an empty field, an empty swatch or a dash in the checkbox (DECISIONS multi-select rule); an edit sets every selected layer in one undo step.
- Appearance reuses the text block's `AppearanceRow` (check, color well, inline value, chevron to a `DetailBand` with keyable rows): Fill (value = opacity %), Outline (value = width), Shadow (value = opacity; detail Opacity, Angle, Distance, Blur). Lines have no Fill row.
- Shadow on adds one Drop Shadow to the layer's effects (catalog defaults), off removes it; that shadow is not listed again under Effects.
- Header (`GraphicsHeaderBar`, 32 pt, `titlebar` fill, hairline below) above the list: clip name `bodyStrong`, layer count `label3`, "Save as Template…" `SQButton` at the trailing edge.
- No layer selected: section "Intro and Outro" (`SQCheckbox` "Keep intro and outro when trimmed", then Middle `SQSegmented` Hold | Stretch while on).
- Empty states (`GraphicsEmptyState`): a text or shape clip shows "Edited in Controls" and a disabled "Make Graphic"; anything else the hint and "New Graphics Clip".
- Controls shows a graphics clip as section "Graphic" (`GraphicSectionView`): an "Item" popup (Whole graphic, then the items front first; it is the shared item selection) and one row "<n> layers" with "Edit in Graphics", which brings the panel to the front. With one item picked, Controls below shows that item as its own clip (Motion, Opacity, effects, Shape with keyframe lanes): keys live in Controls only, the Graphics panel rows have no ring or key buttons. With shape items selected, the item basics follow as grid rows (`GraphicItemRows`): Corners (rectangles; one 50 pt value), Fill (check, swatch, opacity %; not for lines and open paths) and Outline (check, swatch, width px), no chevron. They edit the item's Shape effect at the playhead, the same values as the Graphics panel. There is no Fill/Outline bar above the picture.

## Tooling
`scripts/lint-ui.sh` fails on hard-coded colors, fonts and paddings beyond `scripts/lint-ui-baseline.txt`.

## SQFloatingPanel (SQEditorUI, SQFloatingPanel.swift)
Own floating window for tools that stay open next to the editor (first user: Multiband Compressor setup). Borderless NSPanel, level `.floating`, `hidesOnDeactivate` false, not modal: the editor stays usable and playback keeps running. Card = overlay look (`Theme.Overlay.style`, radius 8, hairline) with panel fill; 28 pt title bar (`titlebar` fill, 1 px `divider` below): title in `bodyStrong` / `label`, subtitle (e.g. clip name) in `body` / `label3`, close `IconButton` (xmark) at the right. Drag by the title bar (`performDrag`). Esc and the close button close it. Fixed size (no resize). Origin is remembered per key for the session (`SQFloatingPanelMemory`, not persisted) and clamped so the title bar stays reachable. No system chrome, no vibrancy.

## Floating panel window (SQEditorUI: Shell/FloatingPanelWindow.swift, FloatingPanelState.swift; App: AppController+FloatingPanels.swift)
A dock panel popped out with the tab menu entry "Move to Floating Window". Same card as SQFloatingPanel (borderless NSPanel, overlay look, 28 pt `titlebar` title bar with the panel name) but resizable: invisible `Spacing.lg` grip in the bottom-right corner, minimum = the panel's `minSize` plus the title bar. Title bar buttons: Dock Panel (`minimize`, back to its exact dock position; Esc does the same) and Close Panel (hides it like a docked one). Frames and the floating set are remembered per workspace in `floating-panels.json` next to `workspaces.json` (keyed `edit:<name>` / `color:<paired edit name>`); a frame on a display that is gone moves onto the first screen. No system chrome.

## EQ Curve (SQEditorUI, EQCurveView.swift, EffectControlsEQ.swift)
Inline under the Parametric EQ header in Effect Controls: a "Curve" disclosure row (`InspectorSectionHeader`, closed by default, state in `openColorGroups` under key `eq-curve`) and, while open, a 170 pt row (`content` fill) holding `EQCurveView`. Plot = `field` fill, `Radius.control`; 20 Hz to 20 kHz log axis, +-18 dB, grid lines per 1-9 step of every decade (`separator`, decades full, others half alpha), 6 dB steps, 0 dB line in `label3` at half alpha; labels 100 / 1k / 10k below and +-6 / +-12 inside, `caption` in `label3`. Combined response: 1.5 pt `accent` line over an `accentTint` area to the 0 dB line. One 6 pt-radius point per band (HP and LP sit on the curve, the rest at their gain): `label` fill with `divider` edge, `accent` while dragged, off bands hollow at `disabledAlpha` and not draggable. Drag = frequency and gain, scroll over a point or Option-drag = Q (2x per 40 pt), double-click = reset the band; every point is an accessibility slider element ("Band 2, 400 hertz, 3.0 decibels, Q 1.00"). Edits write the effect's own parameters (same keyframe rule as the sliders, one undo gesture per drag); the path is cached and rebuilt only when the values or the width change. Response math: `ParametricEQResponse` (SQAudioFX), the stage's own coefficients.

## Multiband Compressor setup (SQEditorUI, EffectControlsMultiband.swift)
In Effect Controls the effect shows a button row ("Edit Custom Setup") and a collapsed-by-default "All Parameters" disclosure (`InspectorSectionHeader`, state in `openColorGroups` under key `all-parameters`); the individual parameter rows with their keyframe controls sit below it and appear only when it is open. The button opens an `SQFloatingPanel` (560 x 560 content + title bar "Multiband Compressor" / clip name), one per effect, owned by `MultibandEditorWindows` (survives row rebuilds, closes when the effect is gone). Common grid: 16 pt margin, 96 pt left-aligned label column, four equal band columns, fields 22 high (`Metrics.capsule`), 26 pt rows, sections separated by 1 px `divider` lines with `captionStrong` headings. Top to bottom: top bar (power `IconButton`, accent when on; preset popup; "Link Band Controls" SQCheckbox; "Output Gain (dB)" field at the right); "Bands" heading, band display (CompressorBandsView: draggable crossovers, per-band input level from the bottom in the band color, accentTint gain-reduction bar from the top, bypassed / solo-muted bands at 0.3 alpha), "Crossover (Hz)" row with three fields in the first three columns; "Band Settings": column headers (band name in the band color, accent / warning / green / title purple, range in `label3` below), "Solo / Bypass" S and B SQButton toggles (`S` tints warning, `B` tints accent), rows Threshold (dB), Gain (dB), Ratio (:1), Attack (ms), Release (ms), "Reduction dB" readout; limiter section: "Output Limiter (Brickwall)" SQCheckbox with the live reduction at the right, four fields under captions in the same columns (Threshold, Margin, Attack, Release; dimmed to disabledAlpha while off). Meters read the engine's per-effect feed at 30 Hz while the window is open and show "–" without audio; no spectrum. Linked: a band drag moves all four by the same delta. Only real effect parameters; a drag is one undo gesture; Solo / Bypass / Link have no parameter rows (window only). Render fixture: `scripts/render-panels.sh --only overlay-multiband-window`.

## Export progress window (SQEditorUI, Export/ExportProgressWindow.swift)
`SQFloatingPanel` 380 x 148 (+ 28 title bar "Exporting" / file name), one per running export, owned by `ExportProgressPresenter` (App). 16 pt margin. Top to bottom: 6 pt capsule bar (`fill` track, `accent` progress, `red` on failure) with the percent (`bodyStrong`, `label`) right of it; phase (`body`, `label`) left and "m:ss elapsed  ·  m:ss left" (`body`, `label2`, right aligned) on one row; output path (`caption`, `label3`, middle truncation); message line (confirm text `label2`, error text `red`); right-aligned `SQButton` row, 22 high, 8 pt gaps. Stages: running (Cancel), confirming (text "Stop the export? The partial file is deleted." + Keep Exporting / Stop Export accent, inline, no system alert), done ("Done", Reveal in Finder / Open accent, closes itself after 1 s), failed or stopped (Close accent, error stays). Updates at 10 Hz. Also: Dock tile progress bar, notification when finished in the background. Render fixtures: `scripts/render-panels.sh --only overlay-export-progress-running` (also `-confirm`, `-done`, `-failed`).
## Stabilizer Analyze row (SQEditorUI, EffectControlsStabilize.swift)
Row under the Stabilizer's Method pop-up (tall row height). An `SQButton` at the parameter value column (`ControlsMetrics.valueX`, min 72 wide, `quietButton` high): "Analyze", "Analyze Again" once analyzed, "Cancel" while it runs. Right of it, while analyzing: `TranscribeProgressBar` (4 high) and the percentage in `caption` / `label3`; otherwise the state in `caption` / `label3` ("Not analyzed", "Analyzed", or why Gyroflow cannot run; the button is disabled then). The Method pop-up grays Gyroflow (SQ menu disabled item, tooltip = reason) when the clip cannot use it. Only the chosen method's parameter rows are shown.

## Anonymize sheets (SQEditorUI, AnonymizeDialog.swift)
Two `SQDialog` sheets on the main window, no new component. **Anonymize** (width 452): title "Anonymize", text = clip name and one sentence on what is made; accessory `SQDialogForm`: two `SQDialog.formRow`s with the shared 104 pt label column, "Cover" (`SQSegmented` Face | Whole Person | Skin) and "With" (`SQSegmented` Mosaic | Blur), 104 pt segments; a `formText` line ("N people found on this frame, numbered left to right:", 6 pt above); one `SQCheckbox` row per person ("Person 2 (center)", all on); the hint as a note (`formText`, `label2`, 6 pt above). Buttons "Anonymize" (default), "Cancel". The last Cover / With choice is remembered. **Check These Frames** (width 520), shown after a run that was unsure somewhere: text, then one `formText` line per range ("timecode to timecode  Person N: reason", `label`). Ranges where a person was not followed (the cover is only an estimate there) come first and are all listed; of the other ranges at most 12, then a note line "and N more ranges where the detection was unsure.". Buttons "Go to First" (default, seeks to the first listed range), "Close". Neither sheet promises a result: the words say "best guess" and "check".

## Timeline header: Normal | Fast Cut switch (SQEditorUI, TimelineHeaderBar.swift)
- Mode capsule `TimelineModeChip` (variant B of docs/research/mode-switch), 22 high, fully rounded, left of the timecode: 14 pt icon (`SQIcon.stack` Normal, `.zap` Fast Cut), `iconToLabel` gap, 11 pt label ("Normal" / "Fast"; padding 8 left, 10 right, width fits the longer label). Normal: `fill`, `label2`; Fast Cut: `accentTint` fill, `accent` icon and text (like Snapping / Linked). A click opens an SQ menu under it (`SQContextMenu`): rows "Normal" and "Fast Cut" with icon, one-line help and a check on the current mode; the mode changes only when a row is picked. Sequence state, not session state: picking is ONE undo step that moves no clip (`EditorSession.setTimelineEditMode`); Shift+G does the same. Tooltip names the full mode ("Fast Cut") with its key.
- Fast Cut sequences: attached clips show an attach thread (1 pt `accent` 85 % line at the attach point from the clip to the main-track row, 3 pt triangle on the host edge, `ClipDrawing.drawAttachThread`); the selected attached clip's host keeps the faint accent hint. Holes on V1 are not hatched yet.
- Preferences > Playback: row "New Sequences Start in", `SQSegmented` Normal | Fast Cut (`sq.newSequenceEditMode`).

## Project chooser overlay and Support entries (App: StartWindow.swift, Toolbar.swift, MenuBuilder.swift)
- Superseded 2026-10-09: the chooser is now the separate start window (see "Start screen" below); the overlay notes here are history. The chooser was an overlay of the main window (`StartOverlayView` in `ShellContentView.overlay`), never a separate window: `Colors.scrim` over the whole content, the card centered with `overlay` radius and `overlayEdge` hairline. The editor behind is inert (clicks end on the scrim, plain keys swallowed, menu items disabled except New / Open / Open Recent / app-level). Esc closes it only when a real project is open behind it (`StartOverlayPolicy`). At launch the workspace panels are hidden behind the scrim until a project is chosen.
- Chooser behavior (update): no sequence exists before a project is chosen (launch and File > Close Project leave `EditorSession` with `makeEmpty()`, no timelines; Close Project shows the chooser again). The card is 920 x 580 (incl. the Support strip), capped by the window minus `Spacing.xl` on every side, down to a 340 x 360 floor; the columns narrow (left 42 % at most), the New/Templates grids wrap and the right column scrolls, the Support strip always stays. Recents show 10 rows, then scroll. The overlay accepts first responder: Up/Down choose a recent, Return opens it (newest when none chosen), Tab / Shift-Tab walk the buttons (SQ focus line), Space presses; Esc closes only with a project open. Quit, Hide, Minimize, Zoom and the Help/Support entries stay enabled. Hand-off: after a project opens or is created the editor is live at once and the chooser fades out over 0.3 s (ease-out, card grows 3 %), Esc 0.15 s; Core Animation only, none with Reduce Motion.
- Top-bar heart menu: `SQMenuItem.caption` (new kind, wrapping, `body`, `label2`, never truncated, menu widens to 240 pt text, help lines wrap at 220 pt, a value list dropped from a control scrolls after 10 rows) then a separator, then rows with `leadingSymbol` (new opt-in leading `SQIcon`, optional tint): heart in `Colors.support`, chat bubbles, code brackets. Opened with `SQContextMenu.popUp(items:belowTrailing:)`: right edge aligned with the heart, kept inside the window. Titles and symbols of all Support places come from `SupportEntry` (SQCore), so heart menu, Help menu and chooser card cannot drift; Discord appears in all three once `SupportLinks.discord` is set.
- Support card: 60 pt strip under the two columns (`panel` fill, black 1 px top line). Left to right: `heart.fill` 16 pt in `Colors.support`, the sentence "Sequence Studio is free, with no ads and no subscription. Your support keeps it that way." (`body`, `label2`, max two lines), a filled "Support" button (`SQButton.accentFillOverride = Colors.support`, heart icon), then quieter standard buttons "Discord" and "GitHub" with icons. Discord is hidden while `SupportLinks.discord` is nil.
- Top bar: one `heart.fill` icon button (`Colors.support` tint, `topControl` wide) at the far right, Export sits left of it. Tooltip "Support Sequence Studio". Click opens an SQ menu: a non-clickable caption row with the card sentence, then "Support Sequence Studio", "Join the Discord", "View on GitHub" (icons).
- Help menu: group at the top, separator after it: "Support Sequence Studio…" (heart in the support color), "Join the Discord", "View on GitHub".
- Export reminder: under a successful export's Reveal / Open buttons, one quiet `.icon` line "Enjoying Sequence Studio? Support it" (heart, support tint) and a "Don't show again" action (`label3`). At most once per 7 days (`sq.support.lastReminder`, a Date), off for good with `sq.support.reminderOff`; never on failure, never a separate popup (`SupportReminder.mayShow`). UI text never says "donate".

## Project panel: source settings rows of the item menu (SQEditorUI, ProjectPanelMenus.swift)
The group above "Reveal in Finder" holds the source settings of the selected media items, each row only when it applies to every selected item: "Pixel Aspect" (submenu), then "Deinterlace": a plain checked `SQMenuItem` row (no submenu), shown only for interlaced media, checked = on (the default), a click flips it for all selected items as one undo step ("Set Deinterlace"). Progressive media has no row.

## Caption track: word boxes, word field, find and replace (SQEditorUI, CaptionWordLayout.swift, TimelineView+CaptionWords.swift, CaptionSearchPopup.swift)
- Word level (from 60 pt/s and 18 pt average word width per caption): the caption is a plate (`clipCaption` at `State.captionPlateAlpha` 0.32, 4 pt radius, edge line; selected: 2 pt `yellow` ring) with one box per word at its real time (`clipCaption`, 3 pt radius, 3 pt above and below, 1 pt between touching boxes, `clipName` text in `onClip`, centered, cut off at the box edge when too long, none under 16 pt). Selected word: 1.5 pt `onClip` ring. Below that zoom: the block with its text as before; under 3 pt a plain sliver.
- Selection has two depths: a click selects the caption, a click on a word of the selected caption selects that word. Delete removes what is selected (the caption, or the word).
- Word field: `SQTextField` over the word, row height, at least 64 pt wide, centered text. No extra chrome. A double-click or Return on the selected word opens it (Escape cancels, Return commits, one undo step); when the zoom cannot reach word level (or the caption has no words, or the track is locked) the Text panel opens instead and the zoom stays.
- Find marks the matches and shows the count while typing; the view moves only on Return, Next and Previous.
- Find and replace: `SQPopover` 356 wide, 12 pt padding, 8 pt between rows of 22: `SQSearchField` + count (`tabularBody`, `label3`) + previous / next / close icon buttons; `SQTextField` "Replace with" + Replace + Replace All; `SQCheckbox` Match Case.

## Caption list, read-only (SQEditorUI, CaptionReadListView.swift)
Rows `Theme.Row.list`: start timecode (`tabularBody`, `label3`, 8 pt inset, 76 pt column), text (`body`, `label2`, one line, ellipsis). Row at the playhead: `selection` fill, text `label`. Selected caption (track selection): `selectedFocused` fill, text `label`; it wins over the playhead mark. Hover: `State.rowHover`. Click seeks. Made for the Controls column as its last section ("All Captions").

## Start screen (design B, App: StartWindow.swift, StartOverlayView.swift, NewProjectSheet.swift)
- Own window (`StartWindowController`, `Metrics.startWindowSize` 1100 x 720, min 820 x 520, frame remembered), never over an empty editor; the editor is its own window and appears only with a project. Closing the last editor brings the start window back; its red button quits when no project is open. Window buttons are the system traffic lights (transparent title bar, full-size content), centered in the 44 pt top bar, 16 pt from the left edge. Every SQ window places them with `SQWindowLights` (always visible, never drawn dots; re-applied after resize, full screen exit and page switch). Status bar save state: "Saved", "Edited", "Edited · Backup 14:32" (`SaveStatus`); version text from `AppVersion`.
- Design B measurements, not the 11 pt editor scale (supersedes the earlier "11 pt start" call): `StartScreenTokens.swift` spacing `startS1…S7` (4…32), radii 8 / 6 / 12, type 11 / 12 / 13 / 15 / 20 with tabular digits (`Typography.start`).
- Top bar 44 (`titlebar`): title after 78 pt traffic-light room, search 260 x 28 (`field`, ⌘F, 2 pt focus ring). Status bar 28: "Projects folder: … · N projects" left, "No project open · Sequence Studio 0.1 Alpha" right.
- Rail 252 (no panel: sits on the canvas; padding 12 top, 8 sides, 8 bottom; buttons 28 high, radius 8, 8 apart, 16 below the last): New project (accentFill, ⌘N), Open… (raised, ⌘O), Import Premiere project (ghost); "Browse" rows Home / Recent (count) / Templates / Learn, 28 high, open tab `fillHover`; Support card on `fill2`; reopen-last checkbox; link row: Appearance, Feedback (Help > Send Feedback), Discord (hidden until its URL exists), GitHub, heart in `support`.
- Pane: header ≥ 56 (20 pt semibold title, count, tools). Recent: grid/list toggle (`sq.start.listLayout`), sort pop button with an SQ menu (Last opened / Name / Frame size, `sq.start.sort`); cards in an adaptive grid (min 168, four columns at 1100) with the project's first-frame still (first video clip of the active sequence, loaded in the background) letter-boxed in its aspect on `content`, neutral fill without one; "Locate media…" over it when that file is missing, aspect badge bottom left, length badge bottom right (black 72 %), "name / W × H · relative time", "…" SQ menu on hover. List rows 44 with frame size, aspect, rate, length, edited. Home: Continue tile and size tiles; Templates: Built in and Yours; Learn: six cards, Keyboard map opens the shortcuts window, the rest say "Soon". Open tab stored in `sq.start.tab` (survives the live Appearance rebuild).
- Appearance popover (`SQPopover`, 300 wide, 12 inset, above the rail link): Dark | Light, Background −6…+6, Contrast 0…100 in steps of 5, "Lowest text contrast x.x:1" (warning under 4.5) and Reset. Settings `sq.appearance.mode|background|contrast` (`ThemeAppearance.shared`), applied live to every window; Theme colors are dynamic (resolved from `AppearancePalette`). Accent #0A84FF, #0A6CF0 for filled controls and in Light.
- New project sheet (`NewProjectSheet`, SQ dialog over the start or editor window, `Colors.scrim` backdrop, 600 wide, radius 14, `panel` fill): header 56 (15 pt semibold title, note, close); form with a 104 pt right-aligned label column, 16 pt column gap, 12 pt row gap: Name, Template (Built in / Yours, hint), Frame size (grouped SQ menu Social / Wide / Cinema + Custom size, aspect shown as key), width x height with swap and aspect hint, Frame rate, Audio, Timeline (Normal | Fast Cut), Outside files, Location (path chip + Choose…). Footer band 68 (`titlebar`): 44 pt aspect preview, "W × H · fps" and "aspect · audio · timeline", Cancel and Create (⏎). Esc cancels, Return creates.
- Not built: Learn pages other than the keyboard map; Mono audio has no project setting yet.

## Overlays (design B: menus, sheets, alerts, tooltips, Settings window)
Tokens in `SQUIKit/OverlayTokens.swift` (`Theme.Menu`, `Theme.Sheet`) plus `Theme.Radius.menu` 10; the mock's menus and sheets
sit outside the editor scope, so they use menu rows 24, radii 10 / 6 / 8 / 14 and 12 pt text.
- Menu (`SQMenuLayout`): `overlay` fill, 0.5 pt edge (the shadowPop ring), radius 10, padding 4, min width 220, rows 24 radius 6
  with padding 8 / 12, hover = `accentFill` with white text, headers 11 semibold `label3` starting over the title column.
- Windows and dialogs: the drawn source is `docs/design-source/v9/editor.html`, view "Modals" (sections `bs-m-system`, `bs-m-about`,
  `bs-m-settings`, `bs-m-seq`, `bs-m-quit`, `bs-m-dialogs`, `bs-m-simplepro`). Modal sizes (the width ladder, `SQModal.Size`): XS 360, S 440, S-list 480, M 600, L 860 x 640. No dialog uses a free width (lint rule `modal-width-literal`); alerts are always S.
  Where the built app and a board differ, the board is a build bug unless the design notes (2026-10-11) says otherwise.
- About (`App/Sources/AppController+About.swift`, content in `AboutContent`): an `SQDialog` of width `.sList` (480) in the modal shell: real app icon
  (104, `NSApp.applicationIconImage`), name (display), `AppVersion.aboutLine`, one line, link buttons GitHub / Support (heart tint) /
  Discord (only when `SupportLinks.discord` is set), License line, supporters, credits. Footer: Acknowledgments left, Done right; the
  Acknowledgments modal has Back left. No website entry.
- Unsaved changes (`SaveChangesPrompt`): one `SQDialog` in the shell for quit, close and replace; Don't Save alone on the left, Cancel,
  Save (Return) right; a never-saved project says Save asks for a place; a failed or canceled save keeps the project open
  (`SaveChangesPrompt.outcome`). The app holds one project at a time, so the board's multi-project list is not built.
- Modal shell (`SQModal`, SQUIKit/SQModal.swift, tokens `Theme.Modal`): every dialog and later window (About, Settings, Sequence
  Settings, Export...) sits in it. A borderless sheet of the main window with the window's frame: the scrim (black 35 %, never a gray or tinted fill: gray over the near-black UI read as a flat blue area, swallows
  clicks and scrolls) covers the whole window, the card is centered (`SQModal.cardFrame`; a card larger than the window keeps 24 free
  per side). Sizes `SQModal.Size`: XS 360, S 440 (`.sList` 480), M 600, L 860 x 640; card radius 14, header 56, footer 68 on the `titlebar`
  band, body padding 20 / 24, label column 104 (S, M) or 132 (L). Footer order is fixed (`SQDialogModel.displayOrder`): "Don't Save"
  alone on the left, other secondary actions, Cancel, the main action last on the right (accent); a destructive action is standard
  with red text. Keys in one place (`SQModal.response`): Return = main action, or the focused button after Tab; never a
  destructive one (Return then presses Cancel and the focus starts on Cancel); Esc and Cmd-. = Cancel; Cmd-D = Don't Save
  (`.dontSave`); Cmd-S = Save (`.save`). Tab walks the buttons (focus line from `SQButton`). `SQDialog` (76 call sites) is the
  API; its window `SQDialogWindow` is the shell. Without a parent window the front window of the app is covered, with no
  window at all the screen. Own cards (Relink, Import Report, Export) present through `SQModalSheet` (same shell, Esc and Cmd-.
  call its `onCancel`); New Project puts its card in an `SQModalScrimView`. `SQSheetWindow` and `NewProjectSheet.ScrimView` are
  gone. The card has the design's drop shadow (`Theme.Modal.shadowAlpha / shadowOffsetY / shadowRadius`: a tight 0 6 20 at 28 %, no wide halo over the scrim).
  Still loose windows: Keyboard Shortcuts, Card Import (planned L modals). Export keeps its 880 x 680 content (bigger than L).
- Alert (`SQDialog` without accessory): width 440 (S), `panel` fill, radius 14, padding 20, title 13 semibold, note 12 `label2`,
  buttons 28 high, radius 8, 12 medium, right aligned, no footer band.
- Sheet (`SQDialog` with `SQDialogForm`): same card, form rows 28 high 12 apart, labels right aligned in a 104 column + 16 gap,
  footer band 68 high on the `titlebar` fill (`SQDialogFooterBand`). `SQButton.cornerRadius` overrides the control radius.
- Sequence Settings / New Sequence (`SequenceSettingsSheet`, size M): form of group captions (`Video`, `Audio`, `Working`,
  `Timecode`, `Preview`; body, `label3`) over rows Name, Preset, Frame Size (two 72 pt fields, x, swap button), Pixel Shape (120 pt popup: Square, then the anamorphic ratios of `PixelAspect.presets`), Frame Rate,
  Sample Rate, Channels (`SQSegmented` Stereo | Mono; Settings only, not in New Sequence), Timeline (`SQSegmented` Normal | Fast Cut), Starts at (timecode field), Display (Timecode | Frames), Quality
  (App setting, Full, 1/2, 1/4). New Sequence shows only the Video and Audio groups. One undo step for all fields. Left out for
  now: Working Space (see DECISIONS).
- Tooltip: padding 8 x 12, radius 8, 12 pt `label2`. Popover: `Theme.Overlay.style` (radius 10).
- Settings (⌘,): an L modal (`SQDialog` on `SQModal`, 860 x 640 via `SQDialog.cardHeight`), title "Settings", one footer button "Done" (settings apply at once). Body: 200 wide sidebar (`SettingsPage`: General, Playback, Editing, Audio, Media, Advanced; icon + title, `fill` when selected, 1 px `separator` on its right) and a scrolling page with 20/24 padding. Every page is `SQFormRow` rows: label column 132 right-aligned (`label2`), 16 gap, control, unit 8 behind it, help text under the control (`label3`, max 440 wide), `captionStrong` group captions starting at the control column. Popups 180 (small 120, amount 92), number fields 64/72. Editing ends with the user's effect and transition defaults as three grouped lists (`fill2` box, 440 wide, Restore Factory per line, empty text "None yet. ..."). Media: Library Folders as a list (folder icon, tilde path, "unavailable" note in `warning`, Remove per line, Add Folder... below), Cache as a read-only path field plus a line with size and Delete Cache. Advanced: Edit API checkbox with a status line under it (8 pt dot: `label3` off, green listening, `warning` port in use; text; copy button for 127.0.0.1:port while listening). Pure model and option inventory: `SettingsPages.swift`.
- `SQFormRow` (SQEditorUI/Settings): the one form row of the L modals. `row(title, controls, help:, extra:)`, `caption`, `unit`, `helpLabel`, `width`, `page`. Row height 28 at least, rows 12 apart; a tall control (list, grid) keeps the label on the first line.

## Color page (2026-10-11)
Top: Program | Source monitor, Scopes tab, Color panel (Controls and Pro tabs). Bottom: one tab group Steps (Pro only) | Timeline | Sources, then the audio meter and Project tabs. All are dock panels with the Edit tab strip, drag-a-tab docking and active marker; the layout persists per page (workspace layout version 5). Strip buttons: Add step (Steps), Copy grade, Paste grade; the quiet detail text after the tabs says what a click does. Color control rows (sliders, wheels block) are capped at `Theme.Inspector.maxRowWidth` and leading-aligned. Steps graph: LUT slot pills size to their label; hint line and Tidy up / Fit / count use the panel inset (`Spacing.md`).

## Consistency rules (2026-10-11)
- Every empty state is `EmptyStateView` (heading `emptyHeading` 15 semibold, hint body in label2, optional action); no panel styles its own.
- Panel header meta text sits right-aligned next to the header icons, never beside the tabs.
- Controls label column is `Theme.Inspector.nameWidth` (88 pt); property names that need more are shortened, not clipped.
- Text-field based labels get +6 pt width over their measured size (NSTextField clips the last glyph).
- Own-design windows (Keyboard Shortcuts, Import from card) carry their title in `SQWindowTitleStrip` (38 pt, `titlebar` fill, hairline, centered title); the system title is hidden.
- Controls names longer than the 88 pt column: widened into free room only in a row without a control, otherwise cut in the middle with an SQ tooltip (`ControlsGrid.place`).
- Export dialog: every row has a label and the same field style; number fields beside popups use the popup fill (`ScrubField.restFill`), no unlabeled rows except the single checkboxes.
- Menus show one shortcut style: every key, punctuation included, is a plain glyph in the right column (no key caps).
- Capsule number fields (`ScrubField`, value and unit) are right-aligned with the unit after the value; only the plain Controls fields stay left-aligned (DECISIONS 2026-10-10).
- Sizes and dates are American whatever the Mac's region is: file sizes through `SQByteSize`, dates with an en_US locale.
- Destructive confirmations: the destructive button first (`.destructive`), Cancel as `.cancel`, so Return never deletes.
- Dialog number fields with a unit (`SQDialog.makeNumberField`, `NumericSlider`, dialog `formRow`/`radioRow`): the unit sits after the capsule, outside it, drawn by `SQUnitLabel` (12 pt `label3`) at `SQDialogMetrics.controlGap` from the field outline; the capsule holds the bare number (`ScrubField.unitOutside`). Rows with and without units share one field edge (`unitFieldWidth` 72, the unit column is reserved). Export follows the same rule (number capsule `ExportDialogView.numberFieldWidth` 84 wide, per the board). Settings uses `SQFormRow.numberRow` and `SQFormRow.unitGrid` (72 wide). Panels keep the unit inside the capsule. L modals (Card Import, Keyboard Shortcuts) use `SQDialogMetrics.lBodyHeight` so the card is exactly 860x640; Export uses the same footer row (`SQDialog.footerRow`: 68 band, 20 inset, summary left, Cancel and Export right); its File Name and Folder rows are the "Output" section of the settings column, as on the board.
- `SQTextField.isInvalid` draws a `red` edge (inline validation, nothing is lost). `SQDialog.canClose` lets a dialog veto a button press so OK stays open while a field is invalid (Sequence Settings "Starts at").
- Card Import uses the shared modal shell footer (`SQDialog.footerRow`, SQButtons), not its own SwiftUI button bar.

## History list and Welcome sheet (SQEditorUI, HistoryDialog.swift; App: AppController+HistoryWelcome.swift)
History (Window > History): an `SQDialog` sheet (sList width) holding `HistoryListView`: a `Theme.Colors.field` well (radius `Radius.well`), 11 rows of `Row.list`, "Original" first, then steps oldest first. Current row: `Colors.selection` pill + `bodyStrong`; undone rows `label3`; click jumps. Welcome (first run, Help > Welcome Tour): `SQDialog` sheet, intro line then bold title + `label2` detail per tip, buttons "Get Started" (default) and "Skip" (leading).

## Menu bar (2026-10-17)
One entry per action: File has a single Import… (the app picks the importer from the file kind) and a single Export… (all formats and interchange targets sit behind "Other Formats…" in the Export dialog). Each menu has at most about 15 entries, no submenu more than 8, nothing scrolls. `EditorMenus.visible` is what the bar builds; `EditorMenus.all` is the full catalog for Quick Apply (Window > Quick Apply) and the audits. Rare variants stay reachable through their key and Quick Apply.
