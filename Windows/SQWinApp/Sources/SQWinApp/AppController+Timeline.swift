import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// The Timeline panel's host side in the Windows shell: commands go through `ShellHost.execute` (the same route as the
/// menu bar and the shortcuts), right-click menus through the shell's one menu system, editors of other panels through
/// `openTimelineEditor` (a status line until that panel lands on Windows).
extension AppController {
    func makeTimelineHost() -> TimelineHost {
        let h = TimelineHost()
        h.command = { [weak self] c in _ = self?.shell.execute(c) }
        h.status = { [weak self] m in self?.shell.onStatus?(m) }
        h.panel = { [weak self] change in if let self { change(&timelinePanel) } }
        h.open = { [weak self] r in self?.openTimelineEditor(r) ?? false }
        h.prompt = { [weak self] p in await self?.askTimelinePrompt(p) }
        h.itemSelection = { [weak self] clip, items in self?.timelineSelectedItems(clip: clip, items: items) }
        return h
    }

    /// Heights kept per sequence and the live duck curve, as the Mac host sets them up.
    func configureTimelinePanel() {
        let media = WinTimelineMedia(paths: paths)
        timelinePanel.connectHostDefaults(session: session, silences: media.silences)
        session.engine.setDialogueSilences(media.silences)     // dialogue pauses release the live duck in playback
        winTimelineMedia = media
        timelinePanel.media = media
        timelinePanel.keyLanes = inspector.keyLanes   // key lanes of the section selected in Effect Controls
        timelinePanel.loadHeightPrefs()
        // Clip menu speed commands toggle the panel's speed band (Show Time Remapping); view commands (Snapping, Linked
        // Selection, Fast Cut, zoom, track heights, edge trims, Edit Marker) need the panel's own state, zoom only when
        // the timeline is the zoom target. Others go on to the shell.
        let next = shell.onCommand
        shell.onCommand = { [weak self] c in
            guard let self else { return next?(c) ?? false }
            let zooms = CommandRouting.zoomTarget(focus: shell.focus, effectControlsFocused: false) == .timeline
            guard let line = timelinePanel.runSpeedCommand(c, session: session)
                    ?? timelinePanel.runViewCommand(c, session: session, zooms: zooms, host: timelineHost) else { return next?(c) ?? false }
            if !line.isEmpty { shell.onStatus?(line) }
            return true
        }
        // Check marks of the timeline toggles and thumbnail mode; the Remove Silences dialog's red preview.
        shell.menuChecks.append { [weak self] in
            guard let self else { return [] }
            return timelinePanel.viewChecks(session: session)
        }
        shell.silencePreview = { [weak self] ranges in self?.timelinePanel.silencePreview = ranges }
        // Undo / Redo scroll the change into view (the Mac `.reveal`).
        let previous = session.onChange
        session.onChange = { [weak self] change in
            previous?(change)
            guard let self, change.contains(.reveal), let r = session.revealRange else { return }
            timelinePanel.reveal(r)
        }
        // Window > Tools shows or hides the tool bar (the strip reads the preference on its next layout).
        let nextAction = shell.onAction
        shell.onAction = { a in
            if case .toggleToolStrip = a { ToolStripPrefs.visible.toggle(); return true }
            return nextAction?(a) ?? false
        }
        configureTimelineDrags()
    }

    /// Rename Track / Rename Clip / Combine / Set Transition Duration: the Mac one-field `SQDialog` as a shell form.
    func askTimelinePrompt(_ p: TimelinePrompt) async -> String? {
        let d = ShellDialog(p.title, informative: p.message)
        d.form = ShellForm([.field(id: "text", label: p.title.hasSuffix("Duration") ? "Duration" : "Name", value: p.text)])
        d.addButton("OK")
        d.addButton("Cancel", role: .cancel)
        guard await shell.ask(d) == .first, let t = d.form?.text("text") else { return nil }
        let s = t.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? (p.placeholder.isEmpty ? nil : p.placeholder) : s
    }

    /// A released key: S ends Hold-S during a timeline drag.
    func timelineKeyUp(_ k: InputKey) {
        shell.keyUp(k)                                     // J/K/L hold state (the Mac key router)
        for a in timelinePanel.keyUp(k) { applyTimeline(a) }
    }

    /// The window lost the keyboard (WM_KILLFOCUS): the key-ups of held J/K/L, tool keys, S and ` never come.
    func releaseHeldKeys() {
        shell.releaseHeldKeys()
        for a in timelinePanel.releaseHeldKeys() { applyTimeline(a) }
    }

    /// A right press on the panel at `p` (panel points): the Mac `timelineMenu(at:)` items at the pointer.
    func showTimelineMenu(at p: CGPoint) {
        guard let items = TimelineMenus.items(at: p, panel: &timelinePanel, session: session, host: timelineHost),
              !items.isEmpty else { return }
        let f = timelinePanel.frame, s = timelinePanel.scale
        let w = CGPoint(x: CGFloat(f.x / s) + p.x, y: CGFloat(f.y / s) + p.y)
        shell.menuBar.controller.present(items: items, at: w, pointer: w)
    }

    /// Editors the timeline opens in other panels; false = not on Windows yet (the timeline shows a status line).
    func openTimelineEditor(_ r: TimelineEditorRequest) -> Bool {
        if let done = openTimelineEditorHere(r) { return done }
        // shortcut: Open in Source is not answered here (the Source monitor belongs to the Monitors work); it shows the
        // timeline's status line until that monitor takes `.source(media:)`.
        switch r {
        case .keyLaneKey(let clip, let time, let extend):
            inspector.model.selectKeyLaneKey(clip: clip, at: time, extend: extend); return true
        case .marker(let id): return shell.editMarker(id)
        case .clipMarker(let clip, let id): return shell.editMarker(id, clip: clip)
        case .textClip(let id), .graphicLayers(let id):
            // Controls shows the Text and Graphic sections of the selected clip.
            session.select(clips: [id], captions: [])
            return true
        case .revealInProject(let id):
            guard session.project.media(id) != nil else { return false }
            projectList.reveal(media: id)
            return true
        default: return false
        }
    }
}

/// The tool bar (SQDrawTimeline `ToolStrip`): docks around the timeline area, picks the panel's tool, opens its menus
/// through the shell's one menu system.
extension AppController {
    /// Lays the bar out in the timeline area (device pixels) and returns what is left for the panel.
    func layoutToolStrip(_ area: DrawRect) -> DrawRect {
        toolStrip.theme = screen.theme
        timelinePanel.syncToggles(session: session)              // the sequence's saved Snapping / Linked Selection
        timelinePanel.followPlayback(playing: !engine.rate.isPaused)
        session.keepAttachedHeld = timelinePanel.toolState.keepAttached   // the ` hold also covers menu and key deletes
        timelineHeader.theme = screen.theme
        timelineHeader.atlas = atlas
        let state = TimelineHeaderState.make(session: session, panel: timelinePanel)
        var underHeader = timelineHeader.layout(area, scale: screen.theme.scale, state: state)
        underHeader = toolStrip.layout(underHeader, scale: screen.theme.scale)
        let content = layoutTrimBar(underHeader)
        for a in toolStrip.tick() { applyToolStrip(a) }
        syncSourcePatch()
        layoutKeystones(content)
        syncItemSelection()
        return content
    }

    func drawToolStrip(_ c: inout Canvas) {
        toolStrip.draw(&c, state: timelinePanel.toolState)
        timelineHeader.draw(&c)
        drawTrimBar(&c)
        timelineDrags.palette.draw(&c)
    }

    /// True when the bar took the event (hover moves go on to the panels).
    func handleToolStrip(_ e: InputEvent) -> Bool {
        if handleTrimBar(e) { if case .mouseMoved = e { return false }; return true }
        if handleKeystones(e) { return true }
        if let actions = timelineHeader.handle(e) {
            for a in actions { applyTimelineHeader(a) }
            if case .mouseMoved = e { return false }
            return true
        }
        guard let actions = toolStrip.handle(e, state: timelinePanel.toolState) else { return false }
        for a in actions { applyToolStrip(a) }
        if case .mouseMoved = e { return false }
        return true
    }

    func applyToolStrip(_ a: ToolStripAction) {
        switch a {
        case .setTool(let s):
            timelinePanel.toolState = s
        case .menu(let m, let p):
            let items = toolStrip.items(m, state: timelinePanel.toolState) { [weak self] s in self?.timelinePanel.toolState = s }
            shell.menuBar.controller.present(items: items, at: p, pointer: p)
        }
    }

    /// The header bar (tabs, Normal | Fast Cut, Snapping, Linked Selection, Add Marker, Fit) and the Fast Cut strip.
    func applyTimelineHeader(_ a: TimelineHeaderAction) {
        switch a {
        case .command(let c): runHeaderCommand(c)
        case .selectTab(let root): session.selectSequenceTab(root: root)
        case .closeTab(let root): session.closeSequenceTab(root: root)
        case .moveTab(let root, let i): session.moveSequenceTab(root: root, to: i)
        case .menu(let m, let p):
            let items = timelineHeader.items(m, toolState: timelinePanel.toolState, fitsTracks: timelinePanel.geometry.fitAllTracks,
                run: { [weak self] c in self?.runHeaderCommand(c) },
                togglePlaceClips: { [weak self] in self?.timelinePanel.toolState.placeSequencesAsClips.toggle() },
                pickMode: { [weak self] mode in
                    guard let self else { return }
                    let line = timelinePanel.setEditMode(mode, session: session)
                    if !line.isEmpty { shell.onStatus?(line) }
                })
            shell.menuBar.controller.present(items: items, at: p, pointer: p)
        }
    }

    /// A header button: the timeline's own view commands first (zoom always targets the timeline here), else the shell.
    func runHeaderCommand(_ c: EditorCommand) {
        if let line = timelinePanel.runViewCommand(c, session: session, zooms: true, host: timelineHost) {
            if !line.isEmpty { shell.onStatus?(line) }
        } else {
            _ = shell.onCommand?(c)
        }
    }
}
