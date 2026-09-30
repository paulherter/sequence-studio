# Sequence Studio — Architecture (Phase 2 engine)

Scope: the playback engine (Route B, see DECISIONS.md 2026-09-30) and the seams the timeline and monitors use.
Slices that build this: docs/STATUS.md "Phase 2 slices". Signatures below are the contract; implementers may add
private helpers and internal types but change a public signature only with a note in this file.

## 1. Data flow

```
           main actor                         render thread (CAMetalDisplayLink)          decode tasks
EditorSession ──setTimeline/seek/play──▶ PlaybackEngine ──snapshot (Mutex)──▶ RenderLoop ──▶ Compositor ──▶ CAMetalLayer
                                              │                                  ▲    │
                                              │ PlaybackClock.now() ◀── AudioClock    │ FrameCache.frame(key) (non-blocking)
                                              ▼                                        ▼
                                        PrefetchPlanner ──jobs──▶ DecodeScheduler ──▶ VTVideoDecoder ──▶ FrameCache.insert
                                                                     (per media: Demuxer + SampleIndex)
audio: AudioFeeder (thread) ── mixes timeline PCM ahead ──▶ ring buffer ──▶ AVAudioSourceNode ──▶ AVAudioUnitTimePitch ──▶ output
                                                                              └─ consumed-frame counter = master clock
```

Principles:
- **Audio is the master clock**, video follows. With no audible audio (muted, no audio clips, scrubbing) a `HostClock` takes over.
- **Decoded frames are keyed by media + source PTS**, never by timeline position. Timeline edits (trim, move, ripple) never invalidate
  the cache; only the composite changes, and we composite every display frame anyway.
- **The render thread never waits.** On a cache miss it shows the nearest cached earlier frame of that clip (or the last presented
  composite) and counts a dropped frame. Decoding happens only in decode tasks.
- **Time is `SSCore.Time` everywhere in our APIs.** `CMTime` / host ticks / sample counts are converted at the boundary
  (`Time(cm.value, Int64(cm.timescale))`, `Time(sampleCount, 48_000)`, `Time(nanos, 1_000_000_000)`). No `Double` for positions.
- **Failures are per clip.** A damaged file marks its media `.damaged`, the compositor draws a placeholder for that layer, playback continues.

## 2. Module placement

| Module (Package.swift deps) | Contents |
|---|---|
| SSCore (none) | `SequenceFormat`, track flags, In/Out, markers, `Timeline.videoLayers(at:)` / `audioSegments(in:)`, three-point edit, add edit, `PlaybackRate`, `Shuttle`, `Bin`/`rootBin`, `SourceMarks`, `Recovery` (autosave), project file v4 |
| SSMedia (SSCore) | `MediaInfo` probe/import, `SampleIndex`, `Demuxer`, `VideoDecoding` + `VTVideoDecoder`, `AudioSource`/`AssetAudioSource`/`MemoryAudioSource`, `Relink` (`MediaLocator`). Test target `SSMediaTestSupport` (synthetic clips) |
| SSRender (SSCore) | `Compositor` (Metal, YCbCr → linear half float, stacking, placeholder), `Presenter` (texture → drawable, fit) |
| SSPlayback (SSCore, SSMedia, SSRender) | `PlaybackClock` + `HostClock`/`ManualClock`, `RingBuffer`, `AudioFeeder` landed; `FrameCache`, `PrefetchPlanner`, `DecodeScheduler`, `AudioClock`, `AudioEngine`, `ScrubAudio`, `PlaybackEngine`, `PlaybackStats` not yet on main |
| SSAudioFX (SSCore, CRNNoise) | `RealtimeAudioFX` (48 kHz track preset/volume/denoise chain), `OfflineAudioFX`, loudness, presets |
| SSText (SSCore) | Text/caption layout |
| SSTranscribe (SSCore) | Transcription |
| SSLibrary (none) | Media/asset library |
| SSProxy (SSCore) | Proxy generation |
| SSExport (SSCore, SSRender, SSPlayback, SSTranscribe, SSAudioFX) | Export writer, settings, frame source |
| SSEditorUI (SSCore) | Theme, workspace layout tree, timeline view + geometry, viewer view, monitor panels, command map. Testable with `swift test`. |
| App | SwiftUI shell, window/toolbar, menus, `EditorSession` wiring |
| Tools/EngineBench | Release-build executable that measures the Phase 2 acceptance criteria |

SSCore stays free of AVFoundation/AppKit/Metal. SSMedia is the only module that touches `AVAsset`/`VideoToolbox`.

## 3. SSCore additions (value types, tests first)

```swift
public struct SequenceFormat: Sendable, Hashable, Codable {
    public var width: Int, height: Int          // pixels, e.g. 1080×1920
    public var frameDuration: Time              // 1001/30000 for 29.97
    public var audioSampleRate: Int             // 48_000
}
// Timeline gains: format (frameDuration moves into it; keep a computed `frameDuration`), inOut: TimeRange?, markers: [Marker]
// Track gains:    name, isVisible (eye, video), isMuted / isSolo (audio), isTargeted, height (pt, UI hint)
public struct Marker: Sendable, Hashable, Codable, Identifiable { public var id: UUID; public var time: Time; public var name: String }

/// What is visible at one instant. Ordered bottom → top (V1 first). Hidden tracks and gaps are omitted.
public struct LayerRequest: Sendable, Hashable {
    public var clip: Clip.ID, media: UUID, track: Track.ID
    public var sourceTime: Time                 // clip.source.start + (t - clip.start)
}
public struct AudioSegment: Sendable, Hashable {  // one clip's contribution to a timeline range
    public var clip: Clip.ID, media: UUID, track: Track.ID
    public var timeline: TimeRange, sourceStart: Time
}
extension Timeline {
    public func videoLayers(at t: Time) -> [LayerRequest]
    public func audioSegments(in range: TimeRange) -> [AudioSegment]   // honours mute/solo
    public func editPoints() -> [Time]                                  // sorted, for ↑/↓
    public var duration: Time { get }
}

/// Rational playback speed. Negative = reverse. `.zero` = paused.
public struct PlaybackRate: Sendable, Hashable { public var num: Int32; public var den: Int32 }
/// J/K/L state machine (Premiere): L = 1, 2, 4, 8; J mirrors; K stops; K held + L/J = ±1/4; K held + tap = ±1 frame.
public struct Shuttle: Sendable, Equatable {
    public private(set) var rate: PlaybackRate
    public mutating func press(_ key: ShuttleKey) -> ShuttleAction   // .setRate(r) / .step(frames) / .none
    public mutating func release(_ key: ShuttleKey) -> ShuttleAction
}
```

Project file: `ProjectFile.currentVersion` = 4. Migrations keyed by source version: v1→v2 (`frameDuration` → `format`, 1920×1080 / 48 kHz defaults),
v2→v3 (clip `animation`, pass-through), v3→v4 (`rootBin`, `sourceMarks`, optional on decode, pass-through).

Landed since (SSCore):
```swift
public struct Bin: Sendable, Hashable, Codable, Identifiable { id, name, children: [BinItem]; bin(_:), allRefs, contains(_:), parent(of:), mediaIDs }
public enum BinItem { /* bin / media / timeline */ }   public enum BinItemRef { /* id-only handle */ }
// Project: rootBin: Bin (default "Root", id = project id), sourceMarks: [MediaRef.ID: SourceMarks]
// Project bin ops (mutating): normalizeBins(), newBin(name:in:), renameBin(_:to:), move(_:to:at:), deleteBin(_:), sortBin(_:by:ascending:), displayName(of:)
public struct SourceMarks: Sendable, Hashable, Codable { public var markIn: Time?, markOut: Time?; var range: TimeRange? }
// Project: sourceMarks(for:), setSourceIn/Out(_:for:), clearSourceIn/Out(for:), clearSourceMarks(for:)
// Recovery.swift: AutosavePolicy(interval 300 s, keep 10, maxAge 7 d), AutosaveStore(base:policy:writer) write/versions(for:)/prune/read,
//   SessionMarker (begin/end/info, crash detection by pid), RecoveryScanner.scan() -> [RecoveryCandidate], recover(_:), dismiss(_:)
```

## 4. SSMedia

```swift
public struct MediaInfo: Sendable, Hashable, Codable {           // stored on MediaRef (SSCore mirror type, filled by SSMedia)
    public var duration: Time
    public var video: VideoTrackInfo?, audio: AudioTrackInfo?
}
public struct VideoTrackInfo: Sendable, Hashable, Codable {
    public var width: Int, height: Int, codec: String, bitDepth: Int, chroma: String   // "4:2:2"
    public var nominalFrameDuration: Time, isVariableFrameRate: Bool
    public var colorPrimaries: String?, transfer: String?, matrix: String?             // nil = untagged (Sony)
}
public struct AudioTrackInfo: Sendable, Hashable, Codable { public var sampleRate: Int, channels: Int, codec: String }

public enum MediaImporter { public static func probe(_ url: URL) async throws -> (MediaRef, MediaInfo) }

/// Relink (Relink.swift). Pure logic + file system, no AV.
public struct MediaLocator: Sendable {                    // init(projectFolder:searchFolders:maxDepth: 6, durationProbe:)
    public func locate(_ ref: MediaRef) -> LocateResult   // bookmark → original path → project neighbour → fingerprint; resolved only when certain
    public static func fingerprint(of url: URL) -> MediaFingerprint?
    public static func applying(_ url: URL, to ref: MediaRef) -> MediaRef    // name/path/bookmark/fingerprint refreshed, id kept
    public static func relinkOthers(chosen: MediaRef, to: URL, others: [MediaRef]) -> (refs: [MediaRef], report: RelinkReport)
}
// LocateMethod { bookmark, originalPath, projectNeighbour, fingerprint }; LocateResult { resolved: (url, method)?, candidates: [RelinkCandidate] (ranked) }
// RelinkReport { relinked: [UUID: URL], fingerprintMismatch: [UUID], missing: [UUID] }
// No Thumbnailer on main yet.

/// Presentation-ordered frame table of one video track. Pure value, built once per media, testable with synthetic tables.
public struct SampleIndex: Sendable {
    public struct Entry: Sendable, Hashable { public var pts: Time, dts: Time, duration: Time, isSync: Bool, decodeOrdinal: Int }
    public let entries: [Entry]                           // sorted by pts; pts 0 = first presented frame (edit-list offset removed)
    public func frame(at sourceTime: Time) -> Int?        // index of frame with pts ≤ t < next pts (VFR-safe); nil outside
    public func gop(containing index: Int) -> ClosedRange<Int>   // presentation indices decodable from one sync sample
    public func previousSync(before index: Int) -> Int
}

public protocol Demuxing: Sendable {                      // AVSampleCursor / AVSampleBufferGenerator behind it
    var index: SampleIndex { get }
    var formatDescription: CMFormatDescription { get }
    /// Compressed samples needed to decode presentation frames `range`, in decode order (from the GOP's sync sample).
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer]
}

/// One decoded frame. `CVPixelBuffer` is IOSurface-backed and Metal compatible (native format: x422/x420/420v or the
/// Apple lossless-compressed variants). Immutable after creation, hence @unchecked Sendable.
public struct DecodedFrame: @unchecked Sendable {
    public let media: UUID, pts: Time, duration: Time
    public let pixelBuffer: CVPixelBuffer
    public var byteCost: Int { get }                      // CVPixelBufferGetDataSize (or plane sum)
}

public protocol VideoDecoding: Sendable {
    var info: VideoTrackInfo { get }
    var isHardware: Bool { get }
    /// Decodes presentation frames `range` and returns them in PTS order. Continues from the previous call without
    /// reseeking when `range` starts right after the last decoded frame (forward playback). Cancellable (Task).
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame]
    func invalidate()
}
public final class VTVideoDecoder: VideoDecoding { public init(demuxer: any Demuxing, media: UUID, scale: DecodeScale = .full) throws }
public enum DecodeScale: Sendable, Hashable { case full, half, quarter }   // VT destination size (Program monitor quality popup)

public enum MediaError: Error, Sendable { case unreadable, unsupportedCodec(String), decodeFailed(OSStatus), truncated }

/// Timeline-rate PCM access: Float32, non-interleaved, stereo (channel 0/1), at the rate the source was opened with (48 kHz).
/// Returns frames written (fewer only at end of media, 0 past it); caller zero-fills. Blocking: feeder thread only.
public protocol AudioSource: Sendable {
    func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int
}
public final class MemoryAudioSource: AudioSource { public init(left: [Float], right: [Float]); public convenience init(mono: [Float]) }  // tests, generated audio
public final class AssetAudioSource: AudioSource { public let sampleRate: Int; public static func open(url: URL, sampleRate: Int) async throws -> AssetAudioSource }  // AVAssetReader + converter
```

Decoding strategy:
- Forward play/prefetch: decode GOP by GOP; the decoder keeps its session and cursor between contiguous calls.
- Random access / scrub: decode from `previousSync` to the target; **keep every decoded frame of that run** in the cache
  (that is what makes the backward step cheap).
- Reverse play: decode GOPs back to front; each GOP lands in the cache whole, then plays backwards from cache.
- Hardware first (`EnableHardwareAcceleratedVideoDecoder`); Sony H.264 4:2:2 has no software fallback (spike), so a failure there is a clip error, not a retry loop.

## 5. SSRender

```swift
public struct RenderLayer: @unchecked Sendable {          // built per display frame from LayerRequest + FrameCache
    public enum Content { case frame(CVPixelBuffer, colorHint: VideoTrackInfo), placeholder(PlaceholderKind) }
    public var content: Content
    // Phase 4 adds transform/opacity; Phase 3 adds color. Phase 2: aspect-fit into the sequence frame, opaque.
}
public enum PlaceholderKind: Sendable { case offline, damaged, loading }

public final class Compositor: @unchecked Sendable {       // used from the render thread only
    public init(device: MTLDevice) throws
    /// Renders layers bottom → top into `target` (rgba16Float, sequence size, linear Rec.709). Black background.
    public func render(_ layers: [RenderLayer], format: SequenceFormat, into target: MTLTexture, commandBuffer: MTLCommandBuffer)
}
public final class Presenter: @unchecked Sendable {
    public init(device: MTLDevice, layer: CAMetalLayer)
    /// Fits (or scales by `zoom`) `texture` into the drawable, surround = viewer token #0C0C0C, encodes and presents.
    public func present(_ texture: MTLTexture, zoom: ViewerZoom, commandBuffer: MTLCommandBuffer)
}
public enum ViewerZoom: Sendable, Hashable { case fit, percent(Int) }
```

Pending merge (branch-only, not on main): `Compositor.render(_:format:into:commandBuffer:) throws` (throws instead of trapping) and
`RenderLayer` gains `transform` and `colorPipeline` (Phase 3/4 fields the note above anticipated).

YCbCr → RGB uses the matrix from the clip's tags (709 default for untagged). Colour management (S-Log3, HLG, ColorSync
viewer) is Phase 3; Phase 2 output is "tagged Rec.709, gamma as decoded" so later work replaces a stage, not the plumbing.
Risk: Metal sampling of Apple lossless-compressed pixel formats (`&xf2`, `&8v0`). If `CVMetalTextureCache` rejects them,
request the uncompressed format in the VT destination attributes (costs bandwidth, measure in EngineBench).

## 6. SSPlayback

```swift
public protocol PlaybackClock: Sendable {
    /// Current timeline position (not snapped). Safe to call from any thread, lock-free or `Mutex`-guarded.
    func now() -> Time
    var rate: PlaybackRate { get }
    func start(at position: Time, rate: PlaybackRate)
    @discardableResult func stop() -> Time                 // holds (rate 0), returns position where it stopped
    func setRate(_ rate: PlaybackRate)                     // keeps position, atomic re-anchor
    func seek(to position: Time)                           // keeps rate, atomic re-anchor
}
// Model: anchor (position, elapsed) + rate; now() = anchor + (elapsed - anchorElapsed) × rate, exact rational, continuous across re-anchors.
public final class HostClock: PlaybackClock { public init() }   // mach_continuous_time, rational (ns timescale)
public final class ManualClock: PlaybackClock { public init(position: Time = .zero, rate: PlaybackRate = .zero); public func advance(by: Time) }  // tests
public final class AudioClock: PlaybackClock { }           // planned, not on main: derived from RingBuffer.consumedFrames, see §7

/// (FrameCache: pending merge, branch worktree-agent-af1484b4a26699528: adds a default budget and low-water eviction; signature below is the pre-branch contract.)
/// Byte-budgeted cache of decoded frames. Thread-safe (Synchronization.Mutex); lookups never block on decoding.
public struct FrameKey: Sendable, Hashable { public var media: UUID; public var pts: Time; public var scale: DecodeScale }
public protocol CacheCost: Sendable { var byteCost: Int { get } }
public final class FrameCache<Payload: CacheCost>: Sendable {
    public init(budgetBytes: Int)                          // default: 25 % of physical memory, max 8 GB
    public func frame(_ key: FrameKey) -> Payload?
    public func nearest(media: UUID, atOrBefore pts: Time, scale: DecodeScale) -> Payload?
    public func insert(_ payload: Payload, for key: FrameKey)
    /// Evicts until under budget: farthest from `playhead` first; frames behind the play direction weigh ×2.
    public func setFocus(playhead: Time, direction: Int, mapping: @Sendable (FrameKey) -> Time?)
    public var usedBytes: Int { get }
}

/// Pure: decides which GOPs to decode next. Tested with synthetic SampleIndex + Timeline.
public struct PrefetchPlanner: Sendable {
    public struct Job: Sendable, Hashable { public var media: UUID; public var frames: ClosedRange<Int>; public var priority: Int }
    public var lookahead: Time                             // default 2 s ahead in play direction (× |rate|), 0.5 s behind
    public func jobs(timeline: Timeline, playhead: Time, rate: PlaybackRate,
                     indexes: [UUID: SampleIndex], cached: (UUID, Int) -> Bool) -> [Job]
}
public actor DecodeScheduler {                             // runs jobs, one in flight per media, max 4 total; cancels on seek
    public func submit(_ jobs: [PrefetchPlanner.Job])      // replaces the pending queue
    public func cancelAll()
}

@MainActor public final class PlaybackEngine {
    public init(device: MTLDevice, media: MediaResolver) throws
    public func setTimeline(_ timeline: Timeline)          // value snapshot; cheap, called after every edit
    public func attach(_ layer: CAMetalLayer?)             // nil = headless (tests/bench render offscreen)
    public private(set) var position: Time                 // last presented frame, snapped to the frame grid
    public private(set) var rate: PlaybackRate
    public func play(_ rate: PlaybackRate = .init(num: 1, den: 1))
    public func pause()
    public func seek(to t: Time)                           // exact frame, shows it as soon as decoded
    public func step(_ frames: Int)                        // ± frames, plays a 1-frame audio grain
    public func beginScrub(); public func scrub(to t: Time); public func endScrub()   // audio grains while dragging
    public var quality: DecodeScale
    public var onPositionChange: (@MainActor (Time) -> Void)?   // ≤ display rate, for playhead/timecode
    public var stats: PlaybackStats { get }
}
public protocol MediaResolver: Sendable { func demuxer(for media: UUID) throws -> any Demuxing; func audio(for media: UUID) throws -> any AudioSource }
public struct PlaybackStats: Sendable {
    public var presentedFrames: Int, droppedFrames: Int
    public var stepLatencies: [Duration]                   // seek/step call → frame on screen
    public var maxAVDrift: Time                            // |presented video time − audio clock| over the run
    public var cacheBytes: Int
}
```

Render loop (render thread, per `CAMetalDisplayLink` tick): `t = clock.now()` snapped to the sequence frame grid →
if unchanged and nothing invalidated, present nothing → `timeline.videoLayers(at: t)` → map each to `FrameKey` through the
media's `SampleIndex` → cache lookup (miss: `nearest`, count drop, ask scheduler) → `Compositor.render` → `Presenter.present`
→ report `t` to the main actor (coalesced). The engine's mutable state for this thread is one `Mutex<RenderState>`
(timeline snapshot, clock, quality, invalidation flag).

## 7. Audio

- Graph: `AVAudioSourceNode` (our mixer) → `AVAudioUnitTimePitch` (rate = |speed|, pitch preserved) → `mainMixerNode` → output.
  Tap on the source node output for the timeline audio meter (peak/RMS per channel).
- Landed (main): `AudioFeeder`, `RingBuffer` in SSPlayback; `AudioSource`/`AssetAudioSource`/`MemoryAudioSource` in SSMedia; `RealtimeAudioFX` in SSAudioFX.
  `AudioEngine`, `AudioClock`, `ScrubAudio` and the AVAudioEngine graph are not on main yet.
- `AudioFeeder` (own thread) mixes `timeline.audioSegments` from `AudioSource`s into a lock-free SPSC ring buffer at
  timeline rate, **in play direction** (reverse = blocks read backwards and reversed). Render block only copies from the ring,
  never locks, never allocates. Underrun = silence + counter.
- `AudioFeeder(timeline:ring:sampleRate: 48_000, blockFrames: 1024, resolver:)` (resolver: `(UUID) throws -> any AudioSource`): `setTimeline`, `start()`/`stop()`,
  `fill(maxBlocks:)` (one pass on the feeder thread, also used by tests), `mix(...)`, `invalidateSources()`, `position`, `failedReads` (failed segments render silence).
  `seek(to: frame, reverse:)` is callable from any thread: it only sets position/direction and bumps a generation. The feeder thread sees the new
  generation, flushes the ring itself (ring keeps a single producer) and drops blocks mixed under an older generation. In reverse, `frame` is the exclusive upper end.
- `RingBuffer(capacity:)` SPSC stereo Float: `push(left:right:count:)`, `pop(...)` (underrun = silence + `underrunCount`), `flush()`, `availableToRead/Write`,
  `consumedFrames: Int64` (atomic, the clock source).
- `RealtimeAudioFX`: fixed 48 kHz (`sampleRate`), `init(preset:volume:channelCount:maxFrames:denoiser:)`, `process(_:frameCount:timelineSample:)` in place,
  `setPreset/setDenoiseMix/setVolume/setBypass/reset` (thread-safe). `latencySamples` = 480 with denoiser (RNNoise), else 0; constant for its lifetime.
- Clock: `position = anchor + direction × consumedFrames / sampleRate − latency`, where `latency` = TimePitch latency
  + output presentation latency, scaled by |rate|. All rational. Rate change / seek = new anchor (flush ring, 5 ms fade out/in).
- Scrub audio (`ScrubAudio`): while scrubbing or stepping, play short grains (≈ 1 frame, min 40 ms) of source audio at the
  playhead in drag direction, 5 ms raised-cosine crossfades between grains, speed from drag velocity through TimePitch.
  Target: sounds like Premiere (Paul judges).

## 8. Threads and Swift 6

| Context | Runs | Owns / touches |
|---|---|---|
| Main actor | UI, EditorSession, PlaybackEngine API | posts snapshots into `Mutex<RenderState>` |
| Render thread | CAMetalDisplayLink runloop | reads RenderState, FrameCache, clock; owns Compositor/Presenter |
| Decode tasks | `DecodeScheduler` actor + VT callbacks | Demuxer, VTVideoDecoder, writes FrameCache |
| AudioFeeder thread | own `Thread`, high QoS | AudioSources, ring buffer write side |
| Audio render thread | Core Audio | ring buffer read side, atomic counters only |

`CVPixelBuffer`/`MTLTexture` crossing threads are wrapped in `@unchecked Sendable` structs that are immutable after creation.
Shared mutable state uses `Synchronization.Mutex` / `Atomic`, not `NSLock` or `DispatchQueue.sync`.

## 9. Measuring (Tools/EngineBench, release build)

`EngineBench three-stack <sony.mp4>` · `step-back <file>` · `drift <file> --minutes 10` · `scrub <file>`.
Headless: offscreen target paced by a 60 Hz `CAMetalDisplayLink`-equivalent timer, real audio output. Prints `PlaybackStats`
as one table; results go into docs/STATUS.md with commit hash. Media paths come from arguments or `SS_MEDIA_DIR`
(default `~/Documents/Videos`), never from the repo.

## Coordinate convention
Decided 2026-09-30 (Paul). Spatial values (Position, anchor, text layout, caption boxes) are in **sequence pixels**, origin **top-left**, **y down**,
like Premiere's Position values: the centre of a 1080×1920 sequence is (540, 960). Text layout uses points = sequence pixels (scale 1).
Renderers convert to Metal/Core Graphics conventions at their own boundary, never in the model.
