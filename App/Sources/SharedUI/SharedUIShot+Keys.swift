import AppKit
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQUIKit

extension SharedUIShot {
    /// `SQ_SHOT_ONLY=keys`: drives the controller's key handler (what `SharedUIView.keyDown` sends) on the demo project
    /// and prints whether each shortcut did its work, with the pointer-focus the key press follows.
    static func keySweep(_ c: SharedUIController) async {
        let cmd = InputModifiers.command
        func key(_ ch: Character, _ m: InputModifiers = []) { c.handle(.keyDown(.character(ch), modifiers: m)) }
        func click(px x: Float, _ y: Float) {
            c.handle(.mouseDown(x: x, y: y, modifiers: [])); c.handle(.mouseUp(x: x, y: y))
        }
        func report(_ name: String, _ ok: Bool) { print("shared ui keys: \(ok ? "ok  " : "FAIL") \(name)") }
        _ = c.frame(width: 2880, height: 1800)
        let s = c.session
        for (place, rect) in [("timeline", (c.timelinePanel.frame.midX, c.timelinePanel.frame.midY)),
                                  ("inspector", (Float(c.inspector.frame.midX * 2), Float(c.inspector.frame.midY * 2)))] {
            click(px: rect.0, rect.1)
            if let id = s.activeTimeline?.tracks.flatMap(\.clips).first?.id { s.select(clips: [id]) }
            let before = s.undoDepth
            s.renameSelectedClip(to: "Keys \(place)")
            let edited = s.undoDepth
            key("z", cmd)
            report("Cmd-Z after click in \(place) (depth \(before) -> \(edited) -> \(s.undoDepth))", s.undoDepth == before)
            key("z", [cmd, .shift])
            report("Shift-Cmd-Z after click in \(place) (depth \(s.undoDepth))", s.undoDepth == edited)
            key("z", cmd)
        }
    }

}
