# Sequence Studio — Design handoff

Approved UI design (2026-09-30): https://claude.ai/artifact/6mArdzhxkp4P9abYXJHP63 (private canvas).
Screens: 0 Tokens · 1 Edit workspace 9:16 · 2 Keyframes + easing · 3a/3b Captions · 4a/4b/4c Export · 5 Quick color + Scopes · 6 Color page.
Behaviour and flows: docs/UX.md (§7 = visual rules). This file maps the canvas tokens (`tokens.css`) to Swift.

Dark appearance only (Final Cut style). Tokens belong in the app's UI layer (e.g. a `Theme` namespace), never in SSCore.
"System" = use the AppKit/SwiftUI value as is; "custom" = define as a named color (asset catalog or `NSColor(srgbRed:…)`).

## Colors

| Token | Value (sRGB) | Swift | Use |
|---|---|---|---|
| titlebar | #1F1F1F | custom | toolbar, status bar |
| panel | #1A1A1A | custom | panel body |
| content | #161616 | custom | tables, lists |
| rowAlt | white 2.5 % | custom | alternating table rows |
| viewer | #0C0C0C | custom (Metal clear color) | monitor surround |
| timeline | #121212 | custom | timeline lanes |
| lane | #151515 | custom | keyframe lanes, rulers |
| divider | #000000 | custom | 1 pt split-view divider between panes (NSSplitView `.thin`, custom color) |
| separator | white 7.5 % | ≈ `NSColor.separatorColor` | hairlines inside a pane |
| label | white 86 % | `NSColor.labelColor` | primary text |
| label2 | white 62 % | ≈ `secondaryLabelColor` (custom, higher contrast) | secondary text |
| label3 | white 46 % | custom (system tertiary is too faint, 4.5:1 required) | timestamps, units, placeholders |
| fill / fill2 | white 11 % / 6 % | ≈ `NSColor.controlColor` / `quaternarySystemFill` | active tab, popups / segmented track, search |
| fillHover / fillPressed | white 16 % / 22 % | custom | button states |
| field / fieldEdge | black 28 % / white 10 % | ≈ `textBackgroundColor` | number-field well |
| selection | white 10 % | `unemphasizedSelectedContentBackgroundColor` | unfocused selected row |
| accent | #0A84FF | `NSColor.controlAccentColor` (dark) | text, icons, scrub values, selected keyframes |
| accentFill | #0A6CF0 | custom | fills under white text (4.7:1): default button, segmented on, focused row |
| accentRing / accentTint | accent 45 % / 22 % | `keyboardFocusIndicatorColor` / custom | focus ring / targeted track, graph row |
| red / green / yellow | #FF453A / #30D158 / #FFD60A | `systemRed` / `systemGreen` / `systemYellow` | offline, meter, warnings |
| clipVideo (+edge) | #3D67B8 (#6F95DC) | custom | video file clips |
| clipAudio (+edge, wave) | #2F6B3A (#4E9A5A, #9FD98A) | custom | audio clips, waveform |
| clipNest (+edge) | #8A6320 (#C29445) | custom | nested sequences |
| clipTitle (+edge) | #9C3F79 (#CF6AA9) | custom | text, graphics |
| clipCaption (+edge) | #6A4DBD (#9C82E4) | custom | captions |
| clipShade / onClip | black 22 % / #FFFFFF | custom | clip body under name strip / text on clips |
| clipSelect | #FFD60A | `systemYellow` | selected clip border (2 pt) |
| playhead | white 92 % | custom | 1 pt line + small triangle |
| keyframe | #D6D6D6 | custom | unselected keyframe |
| marker / range / rangeEdge | #FF9F0A / white 7 % / white 55 % | `systemOrange` / custom | markers, In/Out band on ruler |
| curveX / curveY | #FF9F0A / #64D2FF | `systemOrange` / `systemCyan` | value/speed graph curves |
| menu / scrim | #222222 95 % / black 38 % | `NSMenu`, `NSPopover` material / sheet dimming | menus, popovers, sheets |

## Type (SF Pro, tabular digits for all numbers)

| Token | Size / weight | Swift |
|---|---|---|
| mini | 10 regular | `.system(size: 10)` — ruler, table headers, status bar |
| small | 11 regular (500 for names) | `NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)` — default UI text |
| body | 13 regular / 600 titles | `NSFont.systemFont(ofSize: 13)` — window title, dialogs, menus |
| timecode | 18 light | `.system(size: 18, weight: .light).monospacedDigit()` — viewer |
| clip | 9.5 regular | custom-drawn clip names |
| meter | 9 regular | meter scale |

No SF Mono. Semibold only for titles and section headers. Numbers: `.monospacedDigit()`.

## Spacing, radii, metrics (pt)

- Spacing: 2 · 4 · 8 · 12 · 16 · 24 (6 = icon to label). Pane divider 1.
- Radii: small 3 (tiny thumbnails) · clip 4 · field 5 · row 6 · card 8 · menu 10 · popover 12 · window 16 · capsule (tabs, buttons, search, toolbar groups).
- Metrics: toolbar 52 · status bar 22 · panel header 30 · Effect Controls row 24 · list row 22 · control height 20 (small) · push button 22.
- Tracks: V1 32 · A1 26 · others 20 (user-resizable) · track header 124 · tool column 38.

## Components

**Native macOS (AppKit/SwiftUI, system look — do not restyle):**
window + unified toolbar with Liquid Glass item groups (import, background tasks, Edit | Color page switch, panel toggles, workspace menu, share/Export) ·
NSSplitView panes · NSSegmentedControl (Value|Speed, Before|After|Split, bitrate mode, captions) · NSPopUpButton (Fit, Full ½ ¼, presets, LUTs, codec…) ·
NSButton push/default, checkbox · NSSearchField · NSTextField (number entry, export fields) · NSTableView/NSOutlineView (Project, export list) ·
source list (Library folders) · NSMenu (easing menu, context menus) · NSPopover (CC preset picker, export queue) · sheet (Export) · NSSlider (timeline zoom, Color page) ·
SF Symbols for every icon.

**Custom, built by us (Metal/AppKit drawing, using the tokens above):**
- **Timeline:** ruler (In/Out band, markers), track headers (target chip, eye, mute/solo), clips (name strip, first frame only on tall tracks, waveform from the bottom, type colors, selection border), playhead, audio meter.
- **Monitors:** Program/Source viewer (Metal, color-managed), on-screen transform and caption handles, transport bar.
- **Keyframe editor:** lanes with keyframe glyphs (diamond linear, circle eased, square hold, summary), in-place Value/Speed graph with bezier handles.
- **Scrubbable value** (accent text, drag to change, click → NSTextField), **animate diamond** toggle, **eye** toggle, ‹ › keyframe navigation.
- **Pane tab strip** (capsule tabs, drag to dock).
- **Color page:** color wheels, centre-origin sliders with colored tracks (Temperature, Tint), scopes (waveform, vectorscope), clip strip.
- **Transcript editor** (NSTextView with word highlight and edited-word underline) and caption style tiles.
