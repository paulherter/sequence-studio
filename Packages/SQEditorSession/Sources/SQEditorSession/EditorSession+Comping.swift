import Foundation
import SQCore

extension EditorSession {
    /// Use Take for In to Out: the selected clip's take plays inside the In..Out range, the other takes of the stack are
    /// off there (one undo step, track switches untouched). The playback bounds are left alone (Loop and Play In to Out
    /// still audition the range, and Undo has nothing else to restore). False when nothing was
    /// done (no single clip, no range, no other take there).
    @discardableResult
    public func useSelectedTakeForRange() -> Bool {
        guard let t = activeTimeline, selection.count == 1, let id = selection.first, let range = t.inOut, !range.isEmpty,
              t.canCompTake(of: id, range: range) else { return false }
        return attempt("Use Take", { try $0.compTake(of: id, range: range) })
    }
}
