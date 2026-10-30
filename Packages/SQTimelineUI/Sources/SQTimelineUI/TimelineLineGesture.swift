import Foundation
import SQCore

/// Phase of a line drag (volume, opacity, item lane) the host turns into one undo step.
public enum VolumeEditPhase: Sendable { case began, changed, ended }

/// One drag on a line or lane of the timeline (Opacity, Volume, Item Range) as the session hears it: the first change
/// starts an undo step, every later one continues it, and the step is ended exactly once, when the drag ends. A click
/// that changed nothing ends nothing. A drag that begins while the last one never ended (a lost mouse-up) ends that
/// one first, so its step is never left open for the next edit to fall into.
@MainActor
public final class TimelineLineGesture {
    private let name: String
    private let replace: (Clip, String, Bool) -> Void
    private let end: () -> Void
    /// A change of the running drag reached the session and its step is still open.
    public private(set) var emitted = false

    /// `replace`: the clip, the undo name, and whether it continues the open step (`EditorSession.replaceClip`).
    /// `end`: ends the session's gesture (`EditorSession.endGesture`).
    public init(name: String, replace: @escaping (Clip, String, Bool) -> Void, end: @escaping () -> Void) {
        self.name = name; self.replace = replace; self.end = end
    }

    public func handle(_ clip: Clip, _ phase: VolumeEditPhase) {
        switch phase {
        case .began: close()
        case .changed:
            replace(clip, name, emitted)
            emitted = true
        case .ended: close()
        }
    }

    private func close() {
        guard emitted else { return }
        emitted = false
        end()
    }
}
