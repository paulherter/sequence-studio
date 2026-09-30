import SSCore
import SSMedia

/// Engine counters, snapshot per read (ARCHITECTURE §6).
public struct PlaybackStats: Sendable, Equatable {
    /// Composites handed to the presenter (a new frame position, or a re-render after an edit / arriving frame).
    public var presentedFrames = 0
    /// Frame positions shown with at least one layer not at its exact frame (nearest earlier frame or loading).
    public var droppedFrames = 0
    /// seek/step call -> first complete composite of the target frame.
    public var stepLatencies: [Duration] = []
    /// |presented video time - audio clock| over the run (read right after each composite while playing on the audio
    /// clock). Stays 0 while the engine runs on the host clock.
    public var maxAVDrift: Time = .zero
    /// Render-loop iterations (display-link ticks, or `tick()` calls when headless). Presents per tick well below
    /// the display rate with no drops means the driver is ticking slowly (e.g. the window is hidden or occluded).
    public var renderTicks = 0
    /// Bytes held by the frame cache.
    public var cacheBytes = 0

    public init() {}
}

extension DecodedFrame: CacheCost {}
