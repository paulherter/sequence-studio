import Foundation
import SQCore
import SQDrawKit

/// What the user asked for; the host applies it through the editor session (no view edits the model itself).
public enum EditorIntent: Sendable, Equatable {
    case seek(Time)
    case beginScrub, scrub(Time), endScrub
    case select(Set<Clip.ID>)
    /// Moves a clip so it starts at `to` on `track`.
    case move(Clip.ID, to: Time, track: Track.ID)
    /// Cuts the clips of `track` at `at`.
    case razor(at: Time, track: Track.ID)
    case delete(ripple: Bool)
    case undo, redo
    case playPause
    case shuttle(ShuttleAction)
    case step(Int)
    case goToStart, goToEnd
    /// A Program monitor command (Mark In / Out, Go to In / Out, Remove In / Out, Add Marker, Clear / Delete Range...).
    case monitor(MonitorAction)
    /// A mark grip dropped on the scrub strip: `.markIn` carries the new In, `.markOut` the stored Out (one frame past
    /// the Out frame), like MonitorPanelModel.onMarkEdit.
    case setMark(MonitorScrubMath.Hit, Time)
    /// A moved or newly dragged range dropped on the strip: stored In and Out (MonitorPanelModel.onRangeEdit).
    case setInOut(TimeRange, MarkedRangeDragPart)
}

/// The editor state a frame is drawn from (read from the session by the host each frame).
public struct EditorSnapshot: Sendable {
    public var projectName: String
    public var timeline: Timeline
    public var labels: LabelResolver
    public var selection: Set<Clip.ID>
    public var playhead: Time
    public var isPlaying: Bool
    /// Status bar text (left).
    public var status: String
    /// The Color page's grade text, right before the sequence format ("" hides it; the Mac `statusBar.setGrade`).
    public var grade = ""

    public init(projectName: String, timeline: Timeline, labels: LabelResolver = LabelResolver(), selection: Set<Clip.ID> = [],
                playhead: Time = .zero, isPlaying: Bool = false, status: String = "") {
        self.projectName = projectName; self.timeline = timeline; self.labels = labels; self.selection = selection
        self.playhead = playhead; self.isPlaying = isPlaying; self.status = status
    }

    public var frameDuration: Time { timeline.format.frameDuration }
    public var duration: Time { timeline.tracks.map(\.end).max() ?? .zero }
}

/// HH:MM:SS:FF of a time at the timeline's frame rate (non-drop).
public enum TimecodeText {
    public static func string(_ t: Time, frameDuration: Time) -> String {
        let frame = max(0, t.frameIndex(frameDuration: frameDuration))
        let fps = max(1, Int64((Double(frameDuration.timescale) / Double(max(1, frameDuration.value))).rounded()))
        let f = frame % fps, s = frame / fps
        func two(_ v: Int64) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(two(s / 3600)):\(two(s / 60 % 60)):\(two(s % 60)):\(two(f))"
    }
}
