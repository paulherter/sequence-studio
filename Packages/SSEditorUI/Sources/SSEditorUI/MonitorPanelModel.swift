import Foundation
import Observation
import SSCore
import SSMedia

public enum MonitorMode: Sendable, Hashable { case program, source }

/// Playback quality. Maps 1:1 to SSMedia `DecodeScale` (`decodeScale` / `init(_:)`).
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
}

@MainActor @Observable
public final class MonitorPanelModel {
    public var mode: MonitorMode = .program
    public var currentTime: Time = .zero
    public var duration: Time = .zero
    public var markIn: Time?
    public var markOut: Time?
    public var isPlaying = false
    public private(set) var zoom: MonitorZoom = .fit
    public private(set) var quality: MonitorQuality = .full
    public var frameDuration: Time
    public var dropFrame = false

    @ObservationIgnored public var onSeek: ((Time) -> Void)?
    @ObservationIgnored public var onAction: ((MonitorAction) -> Void)?
    @ObservationIgnored public var onZoomChange: ((MonitorZoom) -> Void)?
    @ObservationIgnored public var onQualityChange: ((MonitorQuality) -> Void)?

    public init(frameDuration: Time) { self.frameDuration = frameDuration }

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
        MonitorAction.allCases.filter { mode == .source || ($0 != .insert && $0 != .overwrite) }
    }

    public func perform(_ action: MonitorAction) {
        guard availableActions.contains(action) else { return }
        onAction?(action)
    }

    /// Returns false (and does not seek) when the text is not a valid timecode.
    @discardableResult
    public func commitTimecodeText(_ text: String) -> Bool {
        guard let t = timecode.parse(text) else { return false }
        onSeek?(t)
        return true
    }

    public func setZoom(_ z: MonitorZoom) { zoom = z; onZoomChange?(z) }
    /// Shows a zoom that a gesture produced (Hand tool, pinch) without reporting it back.
    public func displayZoom(_ z: MonitorZoom) { zoom = z }
    public func setQuality(_ q: MonitorQuality) { quality = q; onQualityChange?(q) }
}
