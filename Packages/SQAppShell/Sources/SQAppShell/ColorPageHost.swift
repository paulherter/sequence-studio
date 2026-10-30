import Foundation
import SQCore
import SQDrawKit
import SQDrawMonitor
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQInspectorUI
import SQUIKit

/// The Color page of the shared shell (Windows app): the Edit | Color switch in the top bar, the Color settings
/// (`ColorGradeDraw`) on the `.colorInspector` card, the Steps graph (`ColorStepsDraw`) on `.steps`, the Sources strip
/// (`ColorSourcesDraw`) on `.colorClips`, the viewer header (`ColorViewerHeaderDraw`) above the Program monitor and the
/// Step window handles on the monitor (`StepWindowOverlay`), all driven by one `ColorGradeController` as on the Mac
/// (`ColorPanelView`, Toolbar page switch, EditorPanels+StepWindowEdit). Scopes, timeline and meters are the Edit page's
/// hosts on the Color layout's cards.
/// The white-balance eyedropper and Basic Correction Auto measure the shown Program composite through
/// `readProgramFrame` (the platform's GPU read-back); the eyedropper waits for the next click on the Program picture,
/// with the crosshair and the loupe (`loupeUnderPointer`, the screen pixels as in Effect Controls) over the picture.
/// The tab strips of Color settings, Steps and Sources end in their detail text and grade buttons (`ColorStripToolsDraw`,
/// the dock leaves that room through `ShellDock.stripTools`). Split draws the divider line over the Program picture.
/// The Timeline's strip shows its hint and Copy / Paste Grade too while it shares a group (a Timeline-only group has no
/// strip, as on the Mac). The Scopes read `scopesHint` and the status bar `gradeStatus` each frame.
/// Sources tiles draw from `media` (the timeline's thumbnail atlas).
/// shortcut: atlas cells are 160 x 90, so a portrait tile is upscaled from a small crop; give the atlas a second cell
/// size when portrait sequences look soft.
/// Steps leaves the layout while the shown grade is Simple (`ShellDock.transientlyHidden`, the Mac `applyWorkspace`).
/// Coordinates: frames in points, events arrive in pixels.
@MainActor
public final class ColorPageHost {
    public enum Part: Sendable { case grade, steps, sources, header, pageSwitch }

    public let controller: ColorGradeController
    public let grade: ColorGradeDraw
    public let steps: ColorStepsDraw
    public let sources: ColorSourcesDraw
    public let header: ColorViewerHeaderDraw
    public let tools: ColorStripToolsDraw
    public let session: EditorSession
    private let dock: ShellDock
    public private(set) var frames: [Part: CGRect] = [:]
    /// The part with keyboard focus (the last one clicked).
    public private(set) var focus: Part?
    private var pressed: Part?
    private var hoverSwitch: WorkspaceStore.Page?
    /// The Program monitor card (the eyedropper's click target), from `refreshStepWindow`.
    private weak var monitorPanel: MonitorPanel?
    /// A white-balance pick waiting for its click on the Program picture.
    private var pick: (picked: @MainActor () -> Void, done: @MainActor (SIMD3<Float>?) -> Void)? {
        didSet { if pick == nil { pickFrame = nil; pickFrameAsked = false } }
    }
    /// The Program picture the loupe magnifies while picking, read once on the first move over it (the Mac
    /// `ColorPickHub` samples per move). shortcut: one frame per pick at most `loupeWidth` wide, so a playing picture's
    /// loupe stays on the first frame; upgrade by re-reading on each new rendered frame.
    private var pickFrame: ProgramLinearFrame?
    private var pickFrameAsked = false
    static let loupeWidth = 1920
    /// The eyedropper waits for its click (the pointer shows a crosshair).
    public var isPicking: Bool { pick != nil }
    /// The screen pixels around the pointer for the loupe while picking (the platform's `AppScreenSampler`); nil = none.
    public var loupeUnderPointer: (@MainActor () -> ColorLoupe?)?
    /// The loupe and the pointer (points) while picking over the Program picture.
    public private(set) var loupe: (grid: ColorLoupe, pointer: CGPoint)?
    /// The tab strips (window points) of the Color panels that show their tools.
    private var strips: [ColorStripToolsDraw.Panel: CGRect] = [:]
    private var pressedTools: ColorStripToolsDraw.Panel?
    /// The Program monitor's card on the Color page below the viewer header (the Split divider is cut to it).
    private var monitorBody: CGRect?
    /// The clips the Color panel grades, outlined on the timeline while the Color page shows (the Mac `gradeOutline`).
    public var gradeOutline: Set<Clip.ID> { isOnColorPage ? controller.gradeOutline : [] }
    static let stripPanels: [(ColorStripToolsDraw.Panel, PanelID)] = [(.colorInspector, .colorInspector), (.steps, .steps), (.sources, .colorClips),
                                                                       (.timeline, .timeline)]
    /// "On screen: X" for the Scopes card while the Color page shows (the Edit page grades nothing; the Mac line would
    /// go stale there because the hidden controller skips playhead ticks).
    public var scopesHint: String? { isOnColorPage ? controller.onScreenHint : nil }
    /// The status bar's grade text on the Color page ("Pro grade active, 4 steps"), "" elsewhere (the Mac `setGrade`).
    public var gradeStatus: String { isOnColorPage ? controller.gradeStatus : "" }

    /// The shown Program composite read back in working-linear light, `width` pixels wide (nil = full size); nil while
    /// there is none. Without it the eyedropper and Auto beep.
    public var readProgramFrame: (@MainActor (_ width: Int?) -> ProgramLinearFrame?)? {
        didSet { wireSampling() }
    }
    /// The same read-back for a platform whose frame arrives later (the Mac engine captures on its render loop,
    /// `requestFrameCapture`): answers `done` once, nil when there is no picture. Wins over `readProgramFrame`.
    public var requestProgramFrame: (@MainActor (_ width: Int?, _ done: @escaping @MainActor (ProgramLinearFrame?) -> Void) -> Void)? {
        didSet { wireSampling() }
    }
    private var programFrame: (@MainActor (_ width: Int?, _ done: @escaping @MainActor (ProgramLinearFrame?) -> Void) -> Void)? {
        if let requestProgramFrame { return requestProgramFrame }
        guard let read = readProgramFrame else { return nil }
        return { width, done in done(read(width)) }
    }
    /// The Sources tiles' pictures (the platform's timeline thumbnails), asked for at draw time.
    public var media: (@MainActor () -> (any TimelineMediaSource)?)? {
        didSet {
            sources.thumbnail = { [weak self] id, at in
                guard let p = self?.media?()?.picture(media: id, at: at) else { return nil }
                return ColorSourcesDraw.Thumbnail(slot: p.slot, source: (p.source.u0, p.source.v0, p.source.u1, p.source.v1),
                                                  pixelSize: p.pixelSize)
            }
        }
    }

    public static let headerHeight = CGFloat(DrawTheme.Metrics.panelHeader)
    static let switchSegment: CGFloat = 72
    static let switchHeight: CGFloat = 26
    /// v9 `.top .seg{margin-left:16px}`.
    static let switchLead: CGFloat = 16

    /// The Before | After | Split strip above the Program monitor. The Mac app has none (its layout lives in the Color tab's
    /// "..." menu), so its shell turns this off; the Windows shell keeps it.
    public var showsViewerHeader = true

    public var isOnColorPage: Bool { dock.store.page == .color }

    public init(session: EditorSession, menus: MenuController, shell: ShellHost) {
        self.session = session
        dock = shell.dock
        controller = ColorGradeController(session: session)
        grade = ColorGradeDraw(controller: controller)
        steps = ColorStepsDraw(controller: controller)
        sources = ColorSourcesDraw(controller: controller)
        header = ColorViewerHeaderDraw(controller: controller)
        tools = ColorStripToolsDraw(controller: controller)
        // Copy and Paste in the Color panels copy and paste the grade (the Mac `colorView.canCopyGrade` / `canPasteGrade`).
        let grader = controller
        shell.factProviders.append { f in
            f.canCopyGrade = grader.canCopyGrade
            f.canPasteGrade = grader.canPasteGrade
        }
        func present(_ part: Part) -> @MainActor ([SQMenuItem], CGRect) -> Void {
            { [weak self, weak menus] items, anchor in
                guard let self, let menus else { return }
                let o = frames[part]?.origin ?? .zero
                let r = anchor.offsetBy(dx: o.x, dy: o.y)
                menus.present(items: items, at: CGPoint(x: r.minX, y: r.maxY), anchor: r)
            }
        }
        grade.onMenu = present(.grade)
        steps.onMenu = present(.steps)
        sources.onMenu = present(.sources)
        header.onMenu = present(.header)
        tools.onMenu = { [weak menus] items, r in menus?.present(items: items, at: CGPoint(x: r.minX, y: r.maxY), anchor: r) }
        tools.addMenuItems = { [weak self] in self?.steps.addMenuItems() }
        tools.moreMenuItems = { [weak self] in self?.grade.panelMenuItems() ?? [] }
        // LUT files: the platform's LUT chooser (`PanelFileChooser.chooseLUTs`, several files for Add LUTs to Library…),
        // else the shell's one-file chooser.
        let pickLUTs: @MainActor (Bool, @escaping @MainActor ([String]) -> Void) -> Void = { [weak shell] multiple, done in
            guard let files = shell?.files else { return done([]) }
            if let panel = files as? PanelFileChooser { return done(panel.chooseLUTs(multiple: multiple).map(\.path)) }
            Task { @MainActor in
                let url = await files.chooseFile(prompt: SQL10n.string("Choose a LUT (.cube, .3dl)"), directory: nil)
                done(url.map { [$0.path] } ?? [])
            }
        }
        grade.chooseLUTFiles = pickLUTs
        steps.chooseLUTFile = { done in pickLUTs(false) { done($0.first) } }
        // The Color strips' detail and buttons: the dock keeps their room free (whoever set the seam before keeps theirs).
        let previousTools = shell.dock.stripTools
        let measure = shell.dock
        shell.dock.stripTools = { [weak self, weak measure] p in
            guard let self, let m = measure, let panel = Self.stripPanels.first(where: { $0.1 == p })?.0, self.isOnColorPage else {
                return previousTools(p)
            }
            return self.tools.width(panel) { m.measure.width($0, size: CGFloat(DrawTheme.TypeSize.body)) }
        }
        controller.sync([.project, .selection])
        // The session's change hook is shared: keep whoever set it before.
        let previous = session.onChange
        session.onChange = { [weak self] change in
            previous?(change)
            self?.controller.sync(change)
        }
    }

    private func wireSampling() {
        guard let read = programFrame else {
            controller.pickScreenColor = nil
            controller.sampleProgramFrame = nil
            pick = nil
            return
        }
        controller.pickScreenColor = { [weak self] picked, done in self?.pick = (picked, done) }
        controller.sampleProgramFrame = { width, done in read(width) { done($0?.pixels) } }
    }

    /// A click while picking: on the Program picture it samples there (one undo step through the controller); anywhere
    /// else it cancels the pick (the Mac ColorPickHub) and the click goes on. True when the click was the pick.
    private func finishPick(at q: CGPoint) -> Bool {
        guard let p = pick else { return false }
        pick = nil
        guard let panel = monitorPanel, panel.canvasRect.contains(q), panel.canvasRect.width > 0, panel.canvasRect.height > 0,
              let read = programFrame else { return false }
        let r = panel.canvasRect
        let pos = SIMD2(Double((q.x - r.minX) / r.width), Double((q.y - r.minY) / r.height))
        p.picked()
        read(nil) { p.done($0?.average(at: pos)) }
        return true
    }

    // MARK: Layout

    /// The Program monitor's card on the Color page loses the viewer header's strip at its top.
    public func monitorCard(_ card: CGRect?) -> CGRect? {
        guard let card, isOnColorPage else { frames[.header] = nil; monitorBody = nil; return card }
        guard showsViewerHeader else { frames[.header] = nil; monitorBody = card; return card }
        let h = Self.headerHeight
        frames[.header] = CGRect(x: card.minX, y: card.minY, width: card.width, height: h)
        let body = CGRect(x: card.minX, y: card.minY + h, width: card.width, height: max(card.height - h, 0))
        monitorBody = body
        return body
    }

    /// The Edit | Color switch in the top bar, 16 pt after `x` (the Mac bar: after the project name; Windows: after the
    /// menu titles), vertically centered in the `barHeight` tall bar (points).
    /// `shown` false (the start screen): no switch.
    public func layoutSwitch(after x: CGFloat, barHeight: CGFloat, top: CGFloat = 0, shown: Bool = true) {
        guard shown else { frames[.pageSwitch] = nil; return }
        frames[.pageSwitch] = CGRect(x: (x + Self.switchLead).rounded(), y: top + ((barHeight - Self.switchHeight) / 2).rounded(),
                                     width: 2 * Self.switchSegment, height: Self.switchHeight)
    }

    /// The Edit | Color switch centered on the bar's exact horizontal middle (`width` points wide; the Mac bar: project
    /// name left, Export right).
    public func layoutSwitch(centeredIn width: CGFloat, barHeight: CGFloat, top: CGFloat = 0, shown: Bool = true) {
        guard shown else { frames[.pageSwitch] = nil; return }
        let w = 2 * Self.switchSegment
        frames[.pageSwitch] = CGRect(x: ((width - w) / 2).rounded(), y: top + ((barHeight - Self.switchHeight) / 2).rounded(),
                                     width: w, height: Self.switchHeight)
    }

    /// Places the panels on the dock's cards (call after the dock laid out and `monitorCard`).
    public func layout() {
        let on = isOnColorPage
        controller.isOnColorPage = on
        let cards: [(Part, PanelID)] = [(.grade, .colorInspector), (.steps, .steps), (.sources, .colorClips)]
        for (part, id) in cards { frames[part] = dock.contentFrame(id) }
        controller.isActive = on || frames[.grade] != nil
        // Steps is the Pro grade's graph: no Simple grade, no Steps panel (shown, not stored).
        let hidden: Set<PanelID> = on && !controller.proShown ? [.steps] : []
        if dock.transientlyHidden != hidden {
            dock.transientlyHidden = hidden
            for (part, id) in cards { frames[part] = dock.contentFrame(id) }
        }
        controller.stepsShown = on && frames[.steps] != nil
        // Sources on screen: the monitor isolates the picked clip's source; no Timeline, no solo (the Mac applyWorkspace).
        controller.sourcesShown = on && frames[.sources] != nil
        controller.stripVisible = on && dock.shows(.timeline)
        strips = [:]
        if on {
            for (panel, id) in Self.stripPanels {
                if let g = dock.groups.first(where: { $0.selected == id }), g.strip.height > 0 { strips[panel] = g.strip }
            }
        }
        if !isPicking { loupe = nil }
        if let f = frames[.grade] { grade.size = f.size; grade.tick() }
        if let f = frames[.steps] { steps.size = f.size }
        if let f = frames[.sources] { sources.size = f.size }
        if let f = frames[.header] { header.size = f.size }
        if let focus, focus != .pageSwitch, frames[focus] == nil { self.focus = nil }
    }

    // MARK: Draw

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        for part in [Part.grade, .steps, .sources, .header] {
            guard let f = frames[part], f.width > 0, f.height > 0 else { continue }
            c.saveGState()
            c.clip(to: f)
            c.translateBy(x: f.minX, y: f.minY)
            switch part {
            case .grade: grade.theme = theme; grade.draw(&c)
            case .steps: steps.theme = theme; steps.draw(&c)
            case .sources: sources.theme = theme; sources.draw(&c)
            case .header: header.theme = theme; header.draw(&c)
            case .pageSwitch: break
            }
            c.restoreGState()
        }
        tools.theme = theme
        for (panel, strip) in strips {
            tools.draw(&c, panel: panel, strip: strip, reserved: dock.stripTools(Self.stripPanels.first { $0.0 == panel }!.1))
        }
        drawSplitDivider(&c, theme: theme)
        drawSwitch(&c, theme: theme)
        if let l = loupe { l.grid.draw(&c, pointer: l.pointer, in: dock.frame, theme: theme) }
    }

    /// Split: a 1 pt line over the split column of the Program picture with a soft shadow (the Mac `SplitDividerView`,
    /// `Theme.OnPicture.stroke` / `shadow`), cut to the visible part of the picture.
    private func drawSplitDivider(_ c: inout Canvas, theme t: DrawTheme) {
        guard isOnColorPage, controller.splitShown, let panel = monitorPanel, let body = monitorBody,
              let r = Self.splitDividerFrame(canvas: panel.canvasRect, sequenceWidth: panel.sequenceSize.width, bounds: body) else { return }
        c.fill(r.insetBy(dx: -1, dy: 0), t.onPictureShadow)
        c.fill(r, t.onPictureStroke)
    }

    /// The divider's frame (`ProgramSurfaceView.splitDividerFrame`): centered on `ColorBypass.splitWidth` of the
    /// sequence width mapped onto the canvas, spanning the visible part of the picture; nil when none is visible.
    static func splitDividerFrame(canvas: CGRect, sequenceWidth: CGFloat, bounds: CGRect, lineWidth: CGFloat = 1) -> CGRect? {
        let w = max(Int(sequenceWidth.rounded()), 1)
        let x = canvas.minX + canvas.width * CGFloat(ColorBypass.splitWidth(w)) / CGFloat(w)
        let visible = canvas.intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(x: (x - lineWidth / 2).rounded(), y: visible.minY, width: lineWidth, height: visible.height)
    }

    func switchFrame(_ p: WorkspaceStore.Page) -> CGRect? {
        guard let f = frames[.pageSwitch] else { return nil }
        return CGRect(x: f.minX + (p == .edit ? 0 : Self.switchSegment), y: f.minY, width: Self.switchSegment, height: f.height)
    }

    /// The page switch (the Mac `pageSwitch`, SQSegmented with the page icons): one track, the shown page raised.
    private func drawSwitch(_ c: inout Canvas, theme t: DrawTheme) {
        guard let f = frames[.pageSwitch] else { return }
        let fs = CGFloat(DrawTheme.TypeSize.body)
        c.fill(roundedRect: f, radius: CGFloat(DrawTheme.Radius.control), t.fill)
        for (p, icon, title) in [(WorkspaceStore.Page.edit, SQIcon.pageEdit, "Edit"), (.color, .pageColor, "Color")] {
            guard let r = switchFrame(p) else { continue }
            let on = dock.store.page == p
            let inner = r.insetBy(dx: 2, dy: 2)
            if on { c.fill(roundedRect: inner, radius: CGFloat(DrawTheme.Radius.small), t.fillPressed) }
            else if hoverSwitch == p { c.fill(roundedRect: inner, radius: CGFloat(DrawTheme.Radius.small), t.fillHover) }
            let label = SQL10n.string(title)
            let tw = c.size(of: label, fontSize: fs).width, iw: CGFloat = 14, gap = CGFloat(DrawTheme.Spacing.xs)
            let x = (r.midX - (iw + gap + tw) / 2).rounded()
            let color = on ? t.label : t.label2
            c.draw(icon: icon, at: CGPoint(x: x, y: (r.midY - iw / 2).rounded()), size: iw, color)
            c.draw(label, in: CGRect(x: x + iw + gap, y: r.minY, width: tw + 2, height: r.height), fontSize: fs, color)
        }
    }

    // MARK: Step window

    /// Pro grade with a windowed Step selected: its handles over the Program monitor while the monitor shows that clip
    /// (not a text or graphic, no text being typed); each drag is one undo step (EditorPanels.refreshStepWindowEdit).
    public func refreshStepWindow(panel: MonitorPanel, isEditingText: Bool) {
        monitorPanel = panel
        guard isOnColorPage, let t = controller.windowEdit, let tl = session.displayTimeline,
              let clip = session.displayedSelectedClip, clip.id == t.clip,
              let target = OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead,
                                              variant: session.activeVariantID),
              !target.isText, !target.isGraphics, !isEditingText else {
            if panel.stepWindowEdit?.isDragging != true { panel.stepWindowEdit = nil }
            return
        }
        let v = panel.stepWindowEdit ?? makeStepWindow(panel)
        let size = target.size
        v.geometry = StepWindowEditGeometry(layer: ZoomEditGeometry(layer: TransformOverlayGeometry(
            sequenceSize: panel.sequenceSize, viewRect: panel.canvasRect,
            mediaAspect: size.height > 0 ? Double(size.width / size.height) : 16.0 / 9,
            transform: target.displayTransform, mediaPixelSize: size)))
        if !v.isDragging, v.stepWindow != t.window { v.stepWindow = t.window }
    }

    private func makeStepWindow(_ panel: MonitorPanel) -> StepWindowOverlay {
        let v = StepWindowOverlay()
        v.onChange = { [weak self] phase, w in
            guard let self else { return }
            switch phase {
            case .began:
                session.stopPlayback()
                controller.beginWindowEdit()
            case .changed:
                controller.changeWindowEdit(w)
            case .ended:
                controller.changeWindowEdit(w)
                controller.endWindowEdit()
            }
        }
        panel.stepWindowEdit = v
        return v
    }

    // MARK: Events

    private func part(at q: CGPoint) -> Part? {
        for p in [Part.pageSwitch, .header, .grade, .steps, .sources] where frames[p]?.contains(q) == true { return p }
        return nil
    }

    /// Routes one event in pixels; true when the page took it.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        func pt(_ x: Float, _ y: Float) -> CGPoint { CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale)) }
        func local(_ q: CGPoint, _ p: Part) -> CGPoint {
            let o = frames[p]?.origin ?? .zero
            return CGPoint(x: q.x - o.x, y: q.y - o.y)
        }
        switch e {
        case .mouseDown(let x, let y, let m):
            let q = pt(x, y)
            if finishPick(at: q) { loupe = nil; return true }
            loupe = nil
            if !m.contains(.secondary), let (panel, strip) = strips.first(where: { $0.value.contains(q) }),
               tools.mouseDown(panel: panel, strip: strip, at: q) {
                pressedTools = panel
                return true
            }
            guard let p = part(at: q) else {
                if focus == .grade { grade.resignFocus() }
                focus = nil
                return false
            }
            if focus == .grade, p != .grade { grade.resignFocus() }
            focus = p
            pressed = p
            let l = local(q, p)
            switch p {
            case .pageSwitch:
                if let page = [WorkspaceStore.Page.edit, .color].first(where: { switchFrame($0)?.contains(q) == true }) {
                    dock.setPage(page)
                }
                pressed = nil
            case .header: header.mouseDown(at: l); pressed = nil
            case .grade: grade.mouseDown(at: l, modifiers: m)
            case .steps: steps.mouseDown(at: l, modifiers: m)
            case .sources: sources.mouseDown(at: l, modifiers: m); pressed = nil
            }
        case .mouseDragged(let x, let y):
            if pressedTools != nil { return true }
            guard let p = pressed else { return false }
            let l = local(pt(x, y), p)
            if p == .grade { grade.mouseDragged(to: l) } else if p == .steps { steps.mouseDragged(to: l) }
        case .mouseUp(let x, let y):
            if let panel = pressedTools {
                pressedTools = nil
                if let strip = strips[panel] { tools.mouseUp(panel: panel, strip: strip, at: pt(x, y)) }
                return true
            }
            guard let p = pressed else { return false }
            pressed = nil
            let l = local(pt(x, y), p)
            if p == .grade { grade.mouseUp(at: l) } else if p == .steps { steps.mouseUp(at: l) }
        case .mouseMoved(let x, let y):
            let q = pt(x, y)
            hoverSwitch = [WorkspaceStore.Page.edit, .color].first { switchFrame($0)?.contains(q) == true }
            let over = part(at: q)
            grade.mouseMoved(to: over == .grade ? local(q, .grade) : nil)
            steps.mouseMoved(to: over == .steps ? local(q, .steps) : nil)
            sources.mouseMoved(to: over == .sources ? local(q, .sources) : nil)
            header.mouseMoved(to: over == .header ? local(q, .header) : nil)
            switch over {
            case .grade?: HostHover.current.offerTip(grade.help(at: local(q, .grade)))
            case .steps?: HostHover.current.offerTip(steps.help(at: local(q, .steps)))
            case .sources?: HostHover.current.offerTip(sources.help(at: local(q, .sources)))
            case .header?: HostHover.current.offerTip(header.help(at: local(q, .header)))
            case .pageSwitch?: HostHover.current.offerTip(hoverSwitch.map { SQL10n.string($0 == .edit ? "Edit Page" : "Color Page") })
            case nil: break
            }
            let strip = strips.first { $0.value.contains(q) }
            tools.mouseMoved(panel: strip?.key, strip: strip?.value, to: q)
            if let (panel, r) = strip { HostHover.current.offerTip(tools.help(panel: panel, strip: r, at: q)) }
            if isPicking, let panel = monitorPanel, panel.canvasRect.contains(q) {
                let r = panel.canvasRect
                let pos = SIMD2(Double((q.x - r.minX) / max(r.width, 1)), Double((q.y - r.minY) / max(r.height, 1)))
                if let grid = loupeUnderPointer?() ?? pickFrame?.loupe(at: pos) {
                    loupe = (grid, q)
                } else {
                    loupe = nil
                    if !pickFrameAsked, let read = programFrame {
                        pickFrameAsked = true
                        read(Self.loupeWidth) { [weak self] f in if self?.isPicking == true { self?.pickFrame = f } }
                        loupe = pickFrame?.loupe(at: pos).map { ($0, q) }   // a read-back that answered at once
                    }
                }
            } else {
                loupe = nil
            }
            return false
        case .scroll(let x, let y, let dx, let dy, let m):
            let q = pt(x, y)
            guard let p = part(at: q) else { return false }
            let ddx = CGFloat(dx / scale), ddy = CGFloat(dy / scale)
            switch p {
            case .grade: grade.scroll(dy: ddy)
            case .steps: steps.scroll(at: local(q, .steps), dx: ddx, dy: ddy, modifiers: m)
            case .sources: sources.scroll(dx: ddx, dy: ddy)
            case .header, .pageSwitch: return false
            }
        case .keyDown(let k, let m):
            if pick != nil, k == .escape { pick = nil; loupe = nil; return true }
            return key(k, modifiers: m)
        }
        return true
    }

    /// Keys for the focused Color panel: Copy / Paste Grade (the Mac Edit menu while a Color panel has focus), then the
    /// panel's own keys.
    func key(_ k: InputKey, modifiers m: InputModifiers) -> Bool {
        guard let f = focus, f == .grade || f == .steps || f == .sources else { return false }
        if m.contains(.command), case .character(let ch) = k {
            switch ch.lowercased() {
            case "c": if !controller.copyGrade() { controller.beep() }; return true
            case "v": if !controller.pasteGrade() { controller.beep() }; return true
            default: break
            }
        }
        switch f {
        case .grade: return grade.key(k, modifiers: m)
        case .steps: return steps.key(k, modifiers: m)
        case .sources: return sources.key(k, modifiers: m)
        case .header, .pageSwitch: return false
        }
    }
}
