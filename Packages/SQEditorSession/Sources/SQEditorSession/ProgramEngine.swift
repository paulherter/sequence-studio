import Foundation
#if os(macOS)
import Metal
import QuartzCore
#endif
import SQCore
import SQMedia
import SQPlayback
#if os(macOS)
import SQRender

/// The layer the Program monitor presents into.
public typealias PreviewSurface = CAMetalLayer
#else
/// The layer the Program monitor presents into. shortcut: no Windows surface type yet (any object), upgrade when the
/// D3D12 swap chain host lands (seam 2).
public typealias PreviewSurface = AnyObject
#endif

/// What the editor needs from the Program playback engine (docs/ARCHITECTURE.md section 6). The real
/// `SQPlayback.PlaybackEngine` conforms (PlaybackEngine+ProgramEngine.swift, Mac); tests run against `StubProgramEngine`.
@MainActor
public protocol ProgramEngine: AnyObject {
    /// Value snapshot of the active sequence plus the sequences it nests (by ID); called after every commit, undo and redo.
    func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline])
    /// nil = headless.
    func attach(_ layer: PreviewSurface?)
    /// Last presented frame, snapped to the frame grid.
    var position: Time { get }
    var rate: PlaybackRate { get }
    func play(_ rate: PlaybackRate)
    func pause()
    func seek(to t: Time)
    func step(_ frames: Int)
    /// The range playback stops or wraps at (nil = whole sequence); the engine wraps a loop itself when `loops` is on.
    var playRange: TimeRange? { get set }
    var loops: Bool { get set }
    /// Frames the preview render cache already decoded (cache warm-up); stand-ins ignore them.
    func seedFrames(_ frames: [DecodedFrame])
    func beginScrub()
    func scrub(to t: Time)
    func endScrub()
    var quality: DecodeScale { get set }
    #if os(macOS)
    /// Viewer Fit / percent zoom (the monitor popup).
    var viewerZoom: ViewerZoom { get set }
    #endif
    /// At most display rate; drives the playhead and timecode.
    var onPositionChange: (@MainActor (Time) -> Void)? { get set }
    #if os(macOS)
    /// Last composited frame (feeds the scopes); nil when nothing was rendered or the engine is a stand-in.
    var lastRenderedTexture: MTLTexture? { get }
    /// Export Frame: the frame at the playhead rendered with every layer decoded at full size (not the viewer quality),
    /// handed to `body` (copy it there), or why there is none (busy, timed out, incomplete). Stand-ins hand over
    /// `lastRenderedTexture`.
    func withFullSizeFrame(_ body: (FullSizeFrameResult) -> Void) async
    /// Asynchronous readback of the finished composite (eyedropper, Auto, thumbnails); coalesced per key, never blocks.
    /// Stand-ins never call `encode`.
    func requestFrameCapture(key: String, _ encode: @escaping FrameCaptureEncoder)
    #endif
    /// True when audio output could not start (playback continues on the host clock).
    var audioUnavailable: Bool { get }
    /// Re-presents the current frame at the viewer's current size (no decode).
    func redraw()
    /// Linear peaks (left, right) of the last metered audio buffer and that buffer's counter; nil without audio output.
    var meterReading: (sequence: Int, peaks: [Float])? { get }
    /// BS.1770 loudness of the same metered signal (momentary / short-term / integrated LUFS, true peak); nil without audio output.
    var loudnessLevels: LoudnessLevels? { get }
    /// Restarts the integrated value and the true-peak hold.
    func resetLoudnessMeter()
    /// Dragging the playhead and stepping play short audio grains (Premiere "audio scrubbing").
    var audioScrubbing: Bool { get set }
    /// Timeline spans with cached frames (ruler strip); empty for stand-ins.
    var cachedSpans: [TimeRange] { get }
    /// Changes whenever the frame cache does (poll gate for `cachedSpans`).
    var cacheGeneration: Int { get }
    /// Debug HUD text with the scrub latency; nil when nothing was measured or for stand-ins.
    var scrubLatencyText: String? { get }
    /// Running total of frame positions shown late during playback (dropped-frame dot); 0 for stand-ins.
    var droppedFrames: Int { get }
    /// Program monitor Transparency Grid: transparent areas show a checkerboard instead of black (monitor only).
    var showsTransparencyGrid: Bool { get set }
    /// Captions drawn over the picture in the monitor (the export burn-in is separate).
    var showsCaptions: Bool { get set }
    /// The project's style kit for the monitor's caption styles (per engine: two open projects do not clash).
    var captionStyleKit: StyleKit? { get set }
    /// The project predates the Inter built-in caption styles: the monitor resolves them to the Helvetica set.
    var captionLegacyFont: Bool { get set }
    /// The files behind these media changed (relink to another path): opened files, decoders, cached frames and audio
    /// sources (playback and scrub) are reopened, so picture and sound switch to the new file.
    func mediaChanged(_ ids: Set<UUID>)
    /// When ready proxies are decoded instead of the originals (W9.9 AutoProxy); stand-ins only record it.
    var proxyUse: ProxyUse { get set }
    /// The proxies of these media appeared, changed or went away (reopened on the next use; originals untouched).
    func proxiesChanged(_ ids: Set<UUID>)
    /// N8b: the project's own live ducking (nil = follow Preferences).
    func setProjectLiveDucking(_ setting: ProjectLiveDucking?)
    /// N8b: dialogue pauses for the live duck (`TimelineWaveforms.silences`).
    func setDialogueSilences(_ provider: (any DialogueSilenceProvider)?)
    /// Q-PERF2 rec 3: thermal / Low Power policy for this monitor (never the export).
    var powerPolicy: PowerPolicy { get set }
    /// Color page Before / Split: these clips drawn without their grade (monitor only; nil = graded).
    func setColorBypass(_ bypass: ColorBypass?)
    #if os(macOS)
    /// Look hover preview: the monitor draws text as the preview says (display only); nil clears it.
    func setLookPreview(_ preview: LookPreview?)
    #endif
}

extension ProgramEngine {
    /// Default: nothing to redraw (stand-ins).
    public func redraw() {}
    /// Default: stand-ins have no range and never wrap by themselves.
    public var playRange: TimeRange? { get { nil } set {} }
    public var loops: Bool { get { false } set {} }
    public func seedFrames(_ frames: [DecodedFrame]) {}
    #if os(macOS)
    public var lastRenderedTexture: MTLTexture? { nil }
    public func withFullSizeFrame(_ body: (FullSizeFrameResult) -> Void) async {
        body(lastRenderedTexture.map { .frame($0) } ?? .failed(.incomplete))
    }
    public func requestFrameCapture(key: String, _ encode: @escaping FrameCaptureEncoder) {}
    public func setLookPreview(_ preview: LookPreview?) {}
    #endif
    public var audioUnavailable: Bool { false }
    public var meterReading: (sequence: Int, peaks: [Float])? { nil }
    public var loudnessLevels: LoudnessLevels? { nil }
    public func resetLoudnessMeter() {}
    public var audioScrubbing: Bool { get { false } set {} }
    public var cachedSpans: [TimeRange] { [] }
    public var cacheGeneration: Int { 0 }
    public var scrubLatencyText: String? { nil }
    public var droppedFrames: Int { 0 }
    public var showsCaptions: Bool { get { true } set {} }
    public var showsTransparencyGrid: Bool { get { false } set {} }
    public var captionStyleKit: StyleKit? { get { nil } set {} }
    public var captionLegacyFont: Bool { get { false } set {} }
    public func mediaChanged(_ ids: Set<UUID>) {}
    public var proxyUse: ProxyUse { get { .off } set {} }
    public func proxiesChanged(_ ids: Set<UUID>) {}
    public func setProjectLiveDucking(_ setting: ProjectLiveDucking?) {}
    public func setDialogueSilences(_ provider: (any DialogueSilenceProvider)?) {}
    public var powerPolicy: PowerPolicy { get { .normal } set {} }
    public func setColorBypass(_ bypass: ColorBypass?) {}
    /// Ends a Look hover preview (portable entry: `setLookPreview(nil)` on the Mac, nothing where there is no preview).
    public func clearLookPreview() {
        #if os(macOS)
        setLookPreview(nil)
        #endif
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
    /// Every `mediaChanged` call, in order.
    public private(set) var changedMedia: [Set<UUID>] = []
    public func mediaChanged(_ ids: Set<UUID>) { changedMedia.append(ids) }
    /// Number of `redraw` calls.
    public private(set) var redrawCount = 0
    public func redraw() { redrawCount += 1 }
    public var proxyUse: ProxyUse = .default
    /// Every `proxiesChanged` call, in order.
    public private(set) var proxyChanges: [Set<UUID>] = []
    public func proxiesChanged(_ ids: Set<UUID>) { proxyChanges.append(ids) }
    /// Every `setProjectLiveDucking` call, in order.
    public private(set) var projectDuckings: [ProjectLiveDucking?] = []
    public func setProjectLiveDucking(_ setting: ProjectLiveDucking?) { projectDuckings.append(setting) }
    /// The last `setColorBypass` value.
    public private(set) var colorBypass: ColorBypass?
    public func setColorBypass(_ bypass: ColorBypass?) { colorBypass = bypass?.isEmpty == true ? nil : bypass }
    #if os(macOS)
    /// The preview the monitor would draw now, and how often it was set (tests).
    public private(set) var lookPreview: LookPreview?
    public func setLookPreview(_ preview: LookPreview?) { lookPreview = preview }
    public var viewerZoom: ViewerZoom = .fit
    #endif
    public private(set) var layer: PreviewSurface?
    public private(set) var position: Time = .zero
    public private(set) var rate: PlaybackRate = .zero
    public var quality: DecodeScale = .full
    public var onPositionChange: (@MainActor (Time) -> Void)?

    public init() {}

    private var frameDuration: Time { timeline?.frameDuration ?? Time(1, 30) }

    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        self.timeline = timeline
        self.sequences = sequences
        timelines.append(timeline)
        calls.append(.setTimeline)
    }

    public func attach(_ layer: PreviewSurface?) { self.layer = layer; calls.append(.attach(layer != nil)) }

    public func play(_ rate: PlaybackRate) { self.rate = rate; calls.append(.play(rate)) }
    /// Test hook: how far ahead of `position` a pause parks while playing (the real engine parks on the frame on the
    /// glass, which leads the last position it reported, and reports it once it is paused).
    public var pauseParksAhead: Time?
    public func pause() {
        let wasPlaying = !rate.isPaused
        rate = .zero; calls.append(.pause)
        if wasPlaying, let ahead = pauseParksAhead { move(to: position + ahead) }
    }

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
