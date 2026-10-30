import Foundation
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQTimelineUI

/// Shows Trim mode for the Mac shared window and Windows: the Program monitor as the Before / After two-up (the Slip
/// two-up's engines), the bar under the timeline, the edit's trimmed side as the timeline's edge selection and the playhead
/// on the trimmed side's frame (the Mac `EditorPanels+Trim` / `TrimMonitorView`). The model and the commands are the
/// shell's (`ShellHost.trim`, `ShellTrim.swift`).
@MainActor public final class TrimModeHost {
    public let shell: ShellHost
    public var bar = TrimBar()
    /// The sequence the trim point was last read against (undo, redo or another edit re-read it).
    private(set) var readTimeline: Timeline?
    private let slip: () -> SlipTwoUpHost?
    private let selectEdges: (EdgeSelection?) -> Void

    public init(shell: ShellHost, slip: @escaping () -> SlipTwoUpHost?, selectEdges: @escaping (EdgeSelection?) -> Void) {
        self.shell = shell
        self.slip = slip
        self.selectEdges = selectEdges
        shell.trim.onChange = { [weak self] in self?.sync() }
    }

    public var isActive: Bool { shell.trim.isActive }

    func sync() {
        let trim = shell.trim
        slip()?.syncTrim(trim)
        bar.update(from: trim)
        readTimeline = shell.session.activeTimeline
        guard let p = trim.point else { return }
        selectEdges(TrimBar.edges(for: p, side: trim.side))
        let f = trim.frames
        if let t = trim.side == .incoming ? f.incoming : (f.outgoing ?? f.incoming) { shell.session.seek(to: t) }
    }

    /// Lays the bar out under the timeline while Trim mode is on and returns what is left for the panel (device pixels).
    public func layout(_ area: DrawRect, theme: DrawTheme) -> DrawRect {
        let trim = shell.trim
        guard trim.isActive else { return area }
        if readTimeline != shell.session.activeTimeline { trim.refresh() }
        guard trim.isActive else { return area }
        let s = theme.scale, k = CGFloat(s)
        let h = min(Float(TrimBar.height) * s, area.h)
        bar.theme = theme
        bar.layout(in: CGRect(x: CGFloat(area.x) / k, y: CGFloat(area.y + area.h - h) / k,
                              width: CGFloat(area.w) / k, height: CGFloat(h) / k), scale: s)
        return DrawRect(x: area.x, y: area.y, w: area.w, h: area.h - h)
    }

    public func draw(_ c: inout Canvas) {
        guard shell.trim.isActive else { return }
        bar.draw(&c)
    }

    /// True when the bar took the event.
    public func handle(_ e: InputEvent) -> Bool {
        let trim = shell.trim
        guard trim.isActive, let actions = bar.handle(e) else { return false }
        for a in actions {
            switch a {
            case .side(let s): trim.select(s)
            case .step(let n): _ = trim.step(frames: n)
            case .done: trim.exit()
            }
        }
        return true
    }
}
