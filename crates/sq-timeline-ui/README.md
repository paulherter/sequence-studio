# sq-timeline-ui

Port of the Swift package `SQTimelineUI`: the portable logic of the timeline view above `sq-editor-session`
(geometry, zoom, the gesture reducer `TimelineInteraction`, snapping feel, layout models for tool strip, menus, drops,
transitions, captions). No drawing: the draw layer is `sq-draw-timeline`. One module per Swift file; Apple-only
branches (`#if canImport(AppKit)`) are not ported, the portable path is the reference.

Test: `cargo xtask check sq-timeline-ui`. Deviations and Swift quirks: `PORTING-NOTES.md`.
