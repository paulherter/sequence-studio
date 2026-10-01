import Foundation
import Metal
import QuartzCore
import SQCore
import SQMedia
import SQPlayback
import SQRender

/// What the editor needs from the Program playback engine (docs/ARCHITECTURE.md section 6). The real
/// `SQPlayback.PlaybackEngine` conforms (below); tests run against `StubProgramEngine`.
@MainActor
public protocol ProgramEngine: AnyObject {
    /// Value snapshot of the active sequence plus the sequences it nests (by ID); called after every commit, undo and redo.
    func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline])
    /// nil = headless.
    func attach(_ layer: CAMetalLayer?)
    /// Last presented frame, snapped to the frame grid.
    var position: Time { get }
    var rate: PlaybackRate { get }
    func play(_ rate: PlaybackRate)
    func pause()
    func seek(to t: Time)
    func step(_ frames: Int)
    func beginScrub()
    func scrub(to t: Time)
    func endScrub()
    var quality: DecodeScale { get set }
    /// Viewer Fit / percent zoom (the monitor popup).
    var viewerZoom: ViewerZoom { get set }
    /// At most display rate; drives the playhead and timecode.
    var onPositionChange: (@MainActor (Time) -> Void)? { get set }
    /// Last composited frame (feeds the scopes); nil when nothing was rendered or the engine is a stand-in.
    var lastRenderedTexture: MTLTexture? { get }
    /// Asynchronous readback of the finished composite (eyedropper, Auto, thumbnails); coalesced per key, never blocks.
    /// Stand-ins never call `encode`.
    func requestFrameCapture(key: String, _ encode: @escaping FrameCaptureEncoder)
    /// True when audio output could not start (playback continues on the host clock).
    var audioUnavailable: Bool { get }
    /// Re-presents the current frame at the viewer's current size (no decode).
    func redraw()
    /// Linear peaks (left, right) of the last metered audio buffer and that buffer's counter; nil without audio output.
    var meterReading: (sequence: Int, peaks: [Float])? { get }
    /// Dragging the playhead and stepping play short audio grains (Premiere "audio scrubbing").
    var audioScrubbing: Bool { get set }
    /// Timeline spans with cached frames (ruler strip); empty for stand-ins.
    var cachedSpans: [TimeRange] { get }
    /// Changes whenever the frame cache does (poll gate for `cachedSpans`).
    var cacheGeneration: Int { get }
    /// Debug HUD text with the scrub latency; nil when nothing was measured or for stand-ins.
    var scrubLatencyText: String? { get }
    /// Captions drawn over the picture in the monitor (the export burn-in is separate).
    var showsCaptions: Bool { get set }
}

extension ProgramEngine {
    /// Default: nothing to redraw (stand-ins).
    public func redraw() {}
    public var lastRenderedTexture: MTLTexture? { nil }
    public func requestFrameCapture(key: String, _ encode: @escaping FrameCaptureEncoder) {}
    public var audioUnavailable: Bool { false }
    public var meterReading: (sequence: Int, peaks: [Float])? { nil }
    public var audioScrubbing: Bool { get { true } set {} }
    public var cachedSpans: [TimeRange] { [] }
    public var cacheGeneration: Int { 0 }
    public var scrubLatencyText: String? { nil }
    public var showsCaptions: Bool { get { true } set {} }
}

extension PlaybackEngine: ProgramEngine {
    public var cachedSpans: [TimeRange] { cachedRanges() }
    public var scrubLatencyText: String? { stats.latencySummary()?.text }
    public var meterReading: (sequence: Int, peaks: [Float])? {
        guard let s = audio?.meterSnapshot() else { return nil }
        return (s.sequence, [s.left.peak, s.right.peak])
    }
}

/// Engine stand-in: records everything it is told and moves `position` on seek/step. Nothing is rendered.
@MainActor
public final class StubProgramEngine: ProgramEngine {
    public enum Call: Equatable, Sendable {
        case setTimeline, attach(Bool), play(PlaybackRate), pause, seek(Time), step(Int)
        case beginScrub, scrub(Time), endScrub
    }

    public private(set) var timeline: Timeline?
    public private(set) var timelines: [Timeline] = []
    public private(set) var sequences: [Timeline.ID: Timeline] = [:]
    public private(set) var calls: [Call] = []
    public private(set) var layer: CAMetalLayer?
    public private(set) var position: Time = .zero
    public private(set) var rate: PlaybackRate = .zero
    public var quality: DecodeScale = .full
    public var viewerZoom: ViewerZoom = .fit
    public var onPositionChange: (@MainActor (Time) -> Void)?

    public init() {}

    private var frameDuration: Time { timeline?.frameDuration ?? Time(1, 30) }

    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        self.timeline = timeline
        self.sequences = sequences
        timelines.append(timeline)
        calls.append(.setTimeline)
    }

    public func attach(_ layer: CAMetalLayer?) { self.layer = layer; calls.append(.attach(layer != nil)) }

    public func play(_ rate: PlaybackRate) { self.rate = rate; calls.append(.play(rate)) }
    public func pause() { rate = .zero; calls.append(.pause) }

    public func seek(to t: Time) {
        calls.append(.seek(t))
        move(to: t)
    }

    public func step(_ frames: Int) {
        calls.append(.step(frames))
        move(to: position + frameDuration * Int64(frames))
    }

    public func beginScrub() { calls.append(.beginScrub) }
    public func scrub(to t: Time) { calls.append(.scrub(t)); move(to: t) }
    public func endScrub() { calls.append(.endScrub) }

    /// Test hook: pretends playback advanced by `dt` (what a real engine reports through `onPositionChange`).
    public func simulatePlayback(advance dt: Time) { move(to: position + dt) }

    private func move(to t: Time) {
        let snapped = max(.zero, t).snapped(to: frameDuration)
        position = snapped
        onPositionChange?(snapped)
    }
}
