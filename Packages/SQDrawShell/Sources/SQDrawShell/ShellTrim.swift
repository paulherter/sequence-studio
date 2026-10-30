import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// Trim mode (TL-08 / TL-09) in the shared shell: the Mac `AppController.executeTrimModeCommand` and its Esc rule, written
/// once for the Mac shared window and Windows. The hosts only show it (the two-up monitor, the bar under the timeline).
extension ShellHost {
    /// Ctrl+Shift+T toggles; while on, Left / Right (Shift: 10 frames), Ctrl+T and J / K / L trim the edit. False = not a Trim
    /// mode command (or Trim mode is off), the command goes on to the panels.
    func runTrimCommand(_ c: EditorCommand) -> Bool {
        if c == .toggleTrimMode {
            if trim.isActive { trim.exit(); return true }
            session.stopPlayback()
            if !trim.enterNearestPlayhead() { flash("Trim mode needs an edit in the sequence.") }
            return true
        }
        guard trim.isActive, focus == nil || focus == .timeline || focus == .programMonitor else { return false }
        switch c {
        case .stepBackward: trim.step(frames: -1)
        case .stepForward: trim.step(frames: 1)
        case .stepBackward5: trim.step(frames: -10)
        case .stepForward5: trim.step(frames: 10)
        case .toggleTrimType: trim.cycleSide()
        case .shuttleForward: trim.dynamicTrim(.l)
        case .shuttleReverse: trim.dynamicTrim(.j)
        case .shuttleStop: trim.dynamicTrim(.k)
        case .playPause, .shuttleSlowForward, .shuttleSlowReverse: flash("Close Trim mode to play.")
        default: return false
        }
        return true
    }

    /// Opens Trim mode at an edit (a double-click on an edge, `TimelineEditorRequest.trimMode`).
    public func enterTrimMode(_ p: TrimPoint, pointerBefore: Bool) {
        session.stopPlayback()
        trim.enter(p, pointerBefore: pointerBefore)
    }
}
