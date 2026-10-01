import Foundation
import AppKit
import Observation
import SQCore
import SQMedia

public enum MonitorMode: Sendable, Hashable { case program, source }

/// Playback quality. Maps 1:1 to SQMedia `DecodeScale` (`decodeScale` / `init(_:)`).
public enum MonitorQuality: String, Sendable, Hashable, CaseIterable {
    case full, half, quarter
    public var divisor: Int { switch self { case .full: 1; case .half: 2; case .quarter: 4 } }
    public var title: String { switch self { case .full: "Full"; case .half: "1/2"; case .quarter: "1/4" } }
    public var decodeScale: DecodeScale { switch self { case .full: .full; case .half: .half; case .quarter: .quarter } }
    public init(_ scale: DecodeScale) { switch scale { case .full: self = .full; case .half: self = .half; case .quarter: self = .quarter } }
}

public enum MonitorZoom: Sendable, Hashable {
    case fit
    case percent(Int)
    /// Reached by pinch or scroll zoom (not a popup preset).
    case custom(Int)
    public static let presets: [MonitorZoom] = [.fit, .percent(25), .percent(50), .percent(75), .percent(100),
                                                .percent(150), .percent(200), .percent(400)]
    public var title: String {
        switch self { case .fit: "Fit"; case .percent(let p), .custom(let p): "\(p)%" }
    }
}

public enum MonitorAction: Sendable, Hashable, CaseIterable {
    case markIn, markOut, goToIn, goToOut, stepBack, stepForward, playPause, addMarker, insert, overwrite
    case lift, extract, exportFrame, loop, playInToOut, toggleSafeMargins

    /// Transport button bar, left to right (Premiere's default order; Loop, Play In to Out and Safe Margins live in
    /// the wrench menu). Insert / Overwrite belong to the Source monitor, Lift / Extract to the Program monitor.
    public static func buttonBar(for mode: MonitorMode) -> [MonitorAction] {
        let edit: [MonitorAction] = mode == .source ? [.insert, .overwrite] : [.lift, .extract]
        return [.addMarker, .markIn, .markOut, .goToIn, .stepBack, .playPause, .stepForward, .goToOut] + edit + [.exportFrame]
    }
}

@MainActor @Observable
public final class MonitorPanelModel {
    public let mode: MonitorMode
    public var currentTime: Time = .zero
    public var duration: Time = .zero
    public var markIn: Time?
    public var markOut: Time?
    public var isPlaying = false
    public private(set) var zoom: MonitorZoom = .fit
    public private(set) var quality: MonitorQuality = .full
    public var frameDuration: Time
    public var dropFrame = false
    /// Loop toggle (wrench menu) and Safe Margins overlay (Program monitor).
    public var isLooping = false
    public var safeMargins = false

    /// Source monitor: the clips opened earlier (title popup, most recent first), the current one, and its markers (M).
    public struct SourceItem: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }
    public var sourceItems: [SourceItem] = []
    public var sourceCurrent: UUID?
    public var markerTimes: [Time] = []
    @ObservationIgnored public var onPickSource: ((UUID) -> Void)?
    @ObservationIgnored public var onCloseSource: (() -> Void)?
    @ObservationIgnored public var onCloseAllSources: (() -> Void)?
    /// Project items dropped on the Source monitor (the first loads, the rest join the history).
    @ObservationIgnored public var onDropMedia: (([UUID]) -> Void)?

    @ObservationIgnored public var onSeek: ((Time) -> Void)?
    @ObservationIgnored public var onAction: ((MonitorAction) -> Void)?
    @ObservationIgnored public var onZoomChange: ((MonitorZoom) -> Void)?
    @ObservationIgnored public var onQualityChange: ((MonitorQuality) -> Void)?
    /// Dragging the timecode scrubs; hosts that need to stop playback or play scrub audio use these, else `onSeek`.
    @ObservationIgnored public var onScrubBegan: (() -> Void)?
    @ObservationIgnored public var onScrub: ((Time) -> Void)?
    @ObservationIgnored public var onScrubEnded: (() -> Void)?
    /// Source Monitor drag: the pasteboard item for dragging the picture (`.both`) or only its video / audio.
    @ObservationIgnored public var dragItem: ((SourceStreams) -> NSPasteboardItem?)?
    @ObservationIgnored public var onDragEnded: (() -> Void)?
    /// A mark grip on the scrub strip was dropped: `.markIn` carries the new In, `.markOut` the new stored Out (one frame
    /// past the Out frame). Called once per drag; while dragging only `markIn` / `markOut` of the model preview it.
    @ObservationIgnored public var onMarkEdit: ((MonitorScrubMath.Hit, Time) -> Void)?
    /// Fills the right-click menu of the picture area.
    @ObservationIgnored public var contextMenuBuilder: ((NSMenu) -> Void)?

    public init(frameDuration: Time, mode: MonitorMode = .program) { self.frameDuration = frameDuration; self.mode = mode }

    public var timecode: Timecode { Timecode(frameDuration: frameDuration, dropFrame: dropFrame) }
    public var timecodeText: String { timecode.format(currentTime) }
    public var durationText: String { timecode.format(duration) }

    /// Length between In and Out (Out defaults to the end, In to the start); nil when neither is set.
    public var inOutDurationText: String? {
        guard markIn != nil || markOut != nil else { return nil }
        let len = (markOut ?? duration) - (markIn ?? .zero)
        return timecode.format(len < .zero ? .zero : len)
    }

    public var availableActions: [MonitorAction] {
        MonitorAction.allCases.filter { a in
            switch a {
            case .insert, .overwrite: mode == .source
            case .lift, .extract, .toggleSafeMargins: mode == .program
            default: true
            }
        }
    }

    /// Time `frames` frames away from `t` (never before zero), for dragging the timecode.
    public func time(offsetFrom t: Time, frames: Int) -> Time {
        max(.zero, (t + frameDuration * Int64(frames)).snapped(to: frameDuration))
    }

    public func perform(_ action: MonitorAction) {
        guard availableActions.contains(action) else { return }
        onAction?(action)
    }

    /// Returns false (and does not seek) when the text is not a valid timecode. `+10` / `-5` move relative to the
    /// current time (frames; `+1:00` is a timecode amount), never before 0 (Premiere).
    @discardableResult
    public func commitTimecodeText(_ text: String) -> Bool {
        if let off = timecode.parseRelative(text) {
            onSeek?(max(.zero, currentTime + off))
            return true
        }
        guard let t = timecode.parse(text) else { return false }
        onSeek?(t)
        return true
    }

    // MARK: Mark grips (drag In / Out on the strip)

    /// Drag preview: moves the In or Out to the frame `frame` (`.playhead` is ignored). Out is stored one frame past it.
    public func previewMark(_ end: MonitorScrubMath.Hit, frame: Time) {
        switch end {
        case .markIn:
            markIn = frame
            if let o = markOut, o <= frame { markOut = nil }
        case .markOut:
            let out = frame + frameDuration
            markOut = out
            if let i = markIn, i >= out { markIn = nil }
        case .playhead: break
        }
    }

    /// Drop: hands the final mark to the host.
    public func commitMark(_ end: MonitorScrubMath.Hit) {
        switch end {
        case .markIn: if let i = markIn { onMarkEdit?(.markIn, i) }
        case .markOut: if let o = markOut { onMarkEdit?(.markOut, o) }
        case .playhead: break
        }
    }

    public func setZoom(_ z: MonitorZoom) { zoom = z; onZoomChange?(z) }
    /// Shows a zoom that a gesture produced (Hand tool, pinch) without reporting it back.
    public func displayZoom(_ z: MonitorZoom) { zoom = z }
    public func setQuality(_ q: MonitorQuality) { quality = q; onQualityChange?(q) }
}
