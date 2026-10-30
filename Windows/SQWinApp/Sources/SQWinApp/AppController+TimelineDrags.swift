import CSQWinApp
import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// What the timeline glue keeps between frames besides the panel: the Window > Keystones card and its list.
/// One window per process, so one instance (AppController's stored properties live in a file other helpers edit).
@MainActor final class TimelineDragState {
    var palette = KeystonePalette()
    let keystones = KeystonesPanelModel()
    /// The Explorer drag hovering now: its files and their ghost items (read once per drag), and whether the ghost shows.
    var explorer: (urls: [URL], items: [DropItem])?
    var explorerGhost = false
}

@MainActor let timelineDrags = TimelineDragState()

/// Drags onto the timeline on Windows, translated from the Mac `EditorPanels` drop wiring: Project list media and
/// sequences, Explorer files, keystones from the Keystones card; plus the item selection shared with Controls.
extension AppController {
    /// Hooks the drag sources; called once from `configureTimelinePanel`.
    func configureTimelineDrags() {
        projectList.onDrag = { [weak self] refs, phase, x, y in self?.projectListDragged(refs, phase, x: x, y: y) }
        AppWindow.dropRoute = { [weak self] urls, x, y in self?.dropFiles(urls, x: x, y: y) ?? false }
        // Window > Keystones shows or hides the card; the menu shows its check mark.
        let nextAction = shell.onAction
        shell.onAction = { a in
            if case .togglePanel(.keystones) = a { timelineDrags.palette.isVisible.toggle(); return true }
            return nextAction?(a) ?? false
        }
        let fill = shell.fillMenuState
        shell.fillMenuState = { s in
            fill?(&s)
            if timelineDrags.palette.isVisible { s.visiblePanels.insert(.keystones) } else { s.visiblePanels.remove(.keystones) }
        }
        configureTimelineEditors()
    }

    // MARK: Project list

    /// Project list items dragged onto the timeline (SQAppShell `TimelineDropRoute`, shared with the Mac shared UI).
    func projectListDragged(_ refs: [BinItemRef], _ phase: ProjectListView.DragPhase, x: Float, y: Float) {
        guard let item = TimelineDropRoute.source(refs) else { return }
        let p: TimelineDropRoute.Phase = switch phase { case .moved: .moved; case .ended: .ended; case .canceled: .canceled }
        let core = source.core
        if TimelineDropRoute.drag(item, phase: p, x: x, y: y, modifiers: keyModifiers(), panel: &timelinePanel, session: session,
                                  sourceTime: { core.mediaID == $0 ? core.currentTime : nil }, status: { [weak self] in self?.status = $0 }) {
            mediaChanged()
        }
    }

    func place(_ source: TimelineDropSource, at a: TimelineAction) {
        if !TimelineDrop.place(source, at: a, in: session), let e = session.lastError { status = e }
        engine.setMedia(session.project.media)
        paths.set(session.project)
    }

    // MARK: Explorer

    /// Media files released over the timeline: imported into the Project panel, then placed where the drop landed.
    /// Anything else (projects, Premiere files, drops elsewhere) goes on to the shell's `importMixed`.
    func dropFiles(_ urls: [URL], x: Float, y: Float) -> Bool {
        guard timelinePanel.contains(x: x, y: y), let model = shell.projectModel,
              urls.allSatisfy({ !ProjectFile.isProjectURL($0) && ShellImportKind.of($0) == .media }) else { return false }
        timelinePanel.dropHover(items: TimelineDrop.items(for: .files(urls), in: session), x: x, y: y, insert: false)
        guard let a = timelinePanel.dropCommit(media: [], x: x, y: y, insert: keyModifiers().contains(.command)).first else {
            return false
        }
        shell.spawn { [weak self] in
            await model.importFiles(urls)
            guard let self else { return }
            shell.onProjectChanged?()
            let ids = urls.compactMap { model.mediaID(forImported: $0) }
            if !ids.isEmpty { place(.media(ids), at: a) }
        }
        return true
    }

    /// The ghost while Explorer files hover over the timeline (the OLE drop target in drop.cpp); called every frame.
    func pollExplorerDrag() {
        var x: Float = 0, y: Float = 0
        guard sq_drop_hover(&x, &y) != 0 else {
            if timelineDrags.explorerGhost { timelinePanel.dropExit() }
            timelineDrags.explorerGhost = false
            timelineDrags.explorer = nil
            return
        }
        if timelineDrags.explorer == nil {
            let n = Int(sq_drop_paths(nil, 0))
            var buf = [UInt16](repeating: 0, count: max(n, 1))
            _ = sq_drop_paths(&buf, Int32(n))
            let urls = buf.prefix(n).split(separator: 0).map { URL(fileURLWithPath: String(decoding: $0, as: UTF16.self)) }
            let media = !urls.isEmpty && urls.allSatisfy { !ProjectFile.isProjectURL($0) && ShellImportKind.of($0) == .media }
            timelineDrags.explorer = (urls, media ? TimelineDrop.items(for: .files(urls), in: session) : [])
        }
        guard let items = timelineDrags.explorer?.items, !items.isEmpty, timelinePanel.contains(x: x, y: y) else {
            if timelineDrags.explorerGhost { timelinePanel.dropExit() }
            timelineDrags.explorerGhost = false
            return
        }
        timelinePanel.dropHover(items: items, x: x, y: y, insert: keyModifiers().contains(.command))
        timelineDrags.explorerGhost = true
    }

    // MARK: Keystones card

    func layoutKeystones(_ area: DrawRect) {
        pollExplorerDrag()
        let s = screen.theme.scale, k = CGFloat(s)
        timelineDrags.palette.theme = screen.theme
        if timelineDrags.palette.isVisible { timelineDrags.palette.keystones = timelineDrags.keystones.keystones }
        timelineDrags.palette.layout(in: CGRect(x: CGFloat(area.x) / k, y: CGFloat(area.y) / k, width: CGFloat(area.w) / k,
                                                height: CGFloat(area.h) / k), scale: s)
    }

    /// True when the card took the event (pointer moves go on).
    func handleKeystones(_ e: InputEvent) -> Bool {
        guard let events = timelineDrags.palette.handle(e) else { return false }
        for ev in events {
            switch ev {
            case .drag(let ks, let x, let y):
                if timelinePanel.contains(x: x, y: y) { timelinePanel.keystoneHover(ks, x: x, y: y) } else { timelinePanel.keystoneExit() }
            case .drop(let ks, let x, let y):
                if timelinePanel.contains(x: x, y: y) { for a in timelinePanel.keystoneDrop(ks, x: x, y: y) { applyTimeline(a) } }
                else { timelinePanel.keystoneExit() }
            case .cancel:
                timelinePanel.keystoneExit()
            case .apply(let ks):
                applyKeystoneToSelection(ks)
            case .menu(let ks, let p):
                showKeystoneMenu(ks, options: false, at: p)
            case .options(let p):
                showKeystoneMenu(nil, options: true, at: p)
            case .delete(let ks):
                deleteKeystone(ks)
            }
        }
        if case .mouseMoved = e { return false }
        return true
    }

    // MARK: Item selection

    /// Controls and the monitor keep the item selection in `session.graphicLayerSelection`; the lanes show it.
    func syncItemSelection() {
        let sel = session.graphicLayerSelection
        let clip = sel.flatMap { session.singleSelectedClip?.id == $0.clip ? $0.clip : nil }
        timelinePanel.setItemSelection(clip: clip, items: sel?.layers ?? [])
    }

    /// The lanes picked items: the shared selection (the bridge already selected the clip).
    func timelineSelectedItems(clip: Clip.ID, items: Set<UUID>) {
        session.graphicLayerSelection = items.isEmpty ? nil : GraphicLayerSelection(clip: clip, layers: items)
        session.notify(.selection)
    }
}
