import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession

/// The timeline's header bar (sequence tabs, Normal | Fast Cut, Snapping, Linked Selection, Add Marker, Fit, the Fast Cut
/// strip) for both shared shells: what Windows `AppController+Timeline` did (`applyTimelineHeader`, `runHeaderCommand`),
/// the AppKit `TimelineHeaderBar`. The timeline panel stays a value in the app, reached through `withPanel`.
/// Coordinates: layout in device pixels (like `ToolStrip`), menu anchors in window points.
@MainActor
public final class TimelineHeaderHost {
    public var strip = TimelineHeaderStrip()
    private let session: EditorSession
    private let shell: ShellHost
    /// Runs `change` on the app's timeline panel.
    private let withPanel: (@MainActor (inout TimelinePanel) -> Void) -> Void
    private let host: () -> TimelineHost?

    public init(session: EditorSession, shell: ShellHost, host: @escaping () -> TimelineHost?,
                withPanel: @escaping (@MainActor (inout TimelinePanel) -> Void) -> Void) {
        self.session = session
        self.shell = shell
        self.host = host
        self.withPanel = withPanel
    }

    /// Lays the bar out at the top of `area` (device pixels) and returns what is left for the panel.
    public func layout(_ area: DrawRect, scale: Float, theme: DrawTheme, atlas: GlyphAtlas?, panel: TimelinePanel) -> DrawRect {
        strip.theme = theme
        strip.atlas = atlas
        return strip.layout(area, scale: scale, state: TimelineHeaderState.make(session: session, panel: panel))
    }

    /// The Mac order (`TimelineHostView`): the header runs across the full width on top, the tool strip docks in what is
    /// below it (on every edge); returns the rect left for the lanes.
    public func layout(_ area: DrawRect, scale: Float, theme: DrawTheme, atlas: GlyphAtlas?, panel: TimelinePanel,
                       toolStrip: inout ToolStrip) -> DrawRect {
        let below = layout(area, scale: scale, theme: theme, atlas: atlas, panel: panel)
        return toolStrip.layout(below, scale: scale)
    }

    public func draw(_ c: inout Canvas) { strip.draw(&c) }

    /// nil = not the bar's event; hover moves come back handled but should go on to the panels too.
    public func handle(_ e: InputEvent) -> Bool? {
        guard let actions = strip.handle(e) else { return nil }
        for a in actions { apply(a) }
        if case .mouseMoved = e { return false }
        return true
    }

    public func apply(_ a: TimelineHeaderAction) {
        switch a {
        case .command(let c): run(c)
        case .selectTab(let root): session.selectSequenceTab(root: root)
        case .closeTab(let root): session.closeSequenceTab(root: root)
        case .moveTab(let root, let i): session.moveSequenceTab(root: root, to: i)
        case .menu(let m, let p):
            var tool = ToolState(), fits = false
            withPanel { tool = $0.toolState; fits = $0.geometry.fitAllTracks }
            let items = strip.items(m, toolState: tool, fitsTracks: fits,
                run: { [weak self] c in self?.run(c) },
                togglePlaceClips: { [weak self] in self?.withPanel { $0.toolState.placeSequencesAsClips.toggle() } },
                pickMode: { [weak self] mode in
                    guard let self else { return }
                    var line = ""
                    withPanel { line = $0.setEditMode(mode, session: self.session) }
                    if !line.isEmpty { shell.onStatus?(line) }
                })
            shell.menuBar.controller.present(items: items, at: p, pointer: p)
        }
    }

    /// A header button: the timeline's own view commands first (zoom always targets the timeline here), else the shell.
    public func run(_ c: EditorCommand) {
        var line: String?
        let h = host()
        withPanel { line = $0.runViewCommand(c, session: self.session, zooms: true, host: h) }
        if let line {
            if !line.isEmpty { shell.onStatus?(line) }
        } else {
            _ = shell.onCommand?(c)
        }
    }
}
