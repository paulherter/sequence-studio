import Foundation
import Metal
import Synchronization
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
import SQRender
@testable import SQPlayback

private let fd = Time(1, 30)
private func frame(_ t: Time) -> Int64 { t.frameIndex(frameDuration: fd) }

/// A clock that reports every `seek` (a loop wrap) to a probe; everything else is the manual clock's.
private final class ProbeClock: PlaybackClock {
    let inner: ManualClock
    let onSeek = Mutex<(@Sendable () -> Void)?>(nil)
    init(_ inner: ManualClock) { self.inner = inner }
    func now() -> Time { inner.now() }
    var rate: PlaybackRate { inner.rate }
    func start(at position: Time, rate: PlaybackRate) { inner.start(at: position, rate: rate) }
    @discardableResult func stop() -> Time { inner.stop() }
    func setRate(_ rate: PlaybackRate) { inner.setRate(rate) }
    func seek(to position: Time) {
        onSeek.withLock { $0 }?()
        inner.seek(to: position)
    }
}

/// Holds a render tick up inside its composite (where it asks for the layers' color pipelines), off the main thread.
private final class TickGate: Sendable {
    let armed = Atomic<Bool>(false)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    func finish() { release.signal(); done.wait() }
}

private struct GatedResolver: MediaResolver {
    let base: StaticMediaResolver
    let gate: TickGate
    func demuxer(for media: UUID) throws -> any Demuxing { try base.demuxer(for: media) }
    func audio(for media: UUID) throws -> any AudioSource { try base.audio(for: media) }
    var colorResolver: LayerColorResolver? {
        if !Thread.isMainThread, gate.armed.exchange(false, ordering: .relaxed) {
            gate.entered.signal()
            gate.release.wait()
        }
        return nil
    }
}

/// One video clip of `frames` frames at 30 fps; with `audio` an audio clip beside it, so the engine plays on the real
/// `AudioClock` (driven by `ManualAudio`: no output, nothing audible).
@MainActor
private struct LeadRig {
    let engine: PlaybackEngine
    let clock: ManualClock
    let audio: ManualAudio?
    let media: UUID
    var host = 100.0

    /// `cutInHalf`: two clips, the second half is a clip of another file (no frame of it is decoded while the first plays).
    static func make(frames: Int64 = 60, audio: Bool = false, cutInHalf: Bool = false,
                     resolver wrap: ((StaticMediaResolver) -> any MediaResolver)? = nil,
                     clock custom: ((ManualClock) -> any PlaybackClock)? = nil) async throws -> LeadRig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec(); spec.frameCount = Int(frames); spec.frameDuration = TestClipSpec.fps(30)
        let file = try await TestClipWriter.write(spec)
        let a = UUID(), clock = ManualClock()
        let output = audio ? ManualAudio() : nil
        let b = UUID()
        var demuxers: [UUID: any Demuxing] = [a: try await AVDemuxer(url: file)]
        if cutInHalf { demuxers[b] = try await AVDemuxer(url: try await TestClipWriter.write(spec)) }
        let base = StaticMediaResolver(demuxers: demuxers)
        let engine = try PlaybackEngine(device: device, media: wrap?(base) ?? base, clock: custom?(clock) ?? clock, audio: output)
        engine.waitsForStartFrame = false
        engine.locksFramePhase = false
        engine.loop.leadsDisplay = true
        let length = fd * frames
        let cut = cutInHalf ? fd * (frames / 2) : length
        var clips = [Clip(name: "c", media: a, kind: .video, source: TimeRange(start: .zero, duration: cut), start: .zero,
                          mediaDuration: length)]
        if cutInHalf {
            clips.append(Clip(name: "d", media: b, kind: .video, source: TimeRange(start: cut, duration: length - cut), start: cut,
                              mediaDuration: length))
        }
        var tracks = [Track(kind: .video, clips: clips)]
        if audio {
            tracks.append(Track(kind: .audio, clips: [Clip(name: "a", media: UUID(), kind: .audio,
                                                           source: TimeRange(start: .zero, duration: length), start: .zero)]))
        }
        engine.setTimeline(Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: fd), tracks: tracks))
        engine.seek(to: .zero)
        await engine.waitForDecodes()
        _ = engine.tick()
        return LeadRig(engine: engine, clock: clock, audio: output, media: a)
    }

    func park(at f: Int64) async {
        engine.seek(to: fd * f)
        await engine.waitForDecodes()
        _ = engine.tick()
    }

    /// Ticks as a display link does, `perFrame` ticks per sequence frame of host time, frames shown 83.3 ms after the
    /// tick. The clock follows host time once it runs: the manual clock is advanced, the audio output renders.
    mutating func ticks(_ count: Int, perFrame: Int = 1, each: (TickOutcome) -> Void = { _ in }) async throws {
        for _ in 0..<count {
            let o = try #require(engine.tick(presentAt: host + 0.0833, hostNow: host))
            await engine.waitForDecodes()
            each(o)
            host += 1.0 / (30 * Double(perFrame))
            if let audio {
                let speed = audio.currentRate.magnitude
                if audio.isPlaying { audio.render(frames: 1600 * Int(speed.num) / (Int(speed.den) * perFrame)) }
            } else if !clock.rate.isPaused {
                clock.advance(by: Time(1, 30 * Int64(perFrame)))
            }
        }
    }
}

/// Display lead on the audio-master path, at rates other than 1x, with short loops and without display ticks.
@Suite(.serialized) @MainActor struct DisplayLeadAudioTests {
    @Test func audioStartsExactlyAtThePlayheadWhenTheMainActorIsLate() async throws {
        var rig = try await LeadRig.make(audio: true)
        let audio = try #require(rig.audio)
        rig.engine.startOnDisplayManually()
        await rig.park(at: 10)
        rig.engine.play()
        #expect(rig.engine.usesAudioClock)
        #expect(!audio.isPlaying, "the clock starts with the display, not before")
        var frames: [Int64] = []
        try await rig.ticks(2) { frames.append(frame($0.time)) }
        #expect(!audio.isPlaying && rig.engine.loop.isStartingPlay)
        // The main actor gets to the start well after the laid-out time: the sound still begins at the playhead.
        rig.host += 0.3
        try await rig.ticks(1) { frames.append(frame($0.time)) }
        #expect(audio.isPlaying)
        #expect(audio.lastSeek == fd * 10)
        var last: TickOutcome?
        try await rig.ticks(14) { frames.append(frame($0.time)); last = $0 }
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b >= a && b <= a + 1, "\(frames)") }
        let o = try #require(last)
        #expect(o.time > o.position && frame(o.position) >= 15, "\(frames)")
    }

    @Test func theLoopWrapsOnTheAudioClock() async throws {
        var rig = try await LeadRig.make(audio: true)
        let audio = try #require(rig.audio)
        rig.engine.startOnDisplayManually()
        rig.engine.loops = true
        await rig.park(at: 50)
        rig.engine.play()
        var frames: [Int64] = [], positions: [Int64] = []
        try await rig.ticks(32) { o in
            frames.append(frame(o.time)); positions.append(frame(o.position))
            #expect(!o.stoppedAtEdge)
        }
        #expect(rig.engine.usesAudioClock && audio.isPlaying && !rig.engine.rate.isPaused)
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == (a + 1) % 60 || b == a, "\(frames)") }
        #expect(frames.contains(59) && frames.contains(0) && frames.contains(1) && frames.contains(2), "\(frames)")
        for (a, b) in zip(positions, positions.dropFirst()) { #expect(b == (a + 1) % 60 || b == a, "\(positions)") }
        #expect(positions.contains(59) && positions.contains(0) && positions.contains(3), "\(positions)")
        // The sound was moved to the loop's beginning, a little into it at most.
        let seek = try #require(audio.lastSeek)
        #expect(seek >= .zero && seek < fd * 2)
    }

    @Test func aReverseLoopOnTheAudioClockPlaysFrameZero() async throws {
        var rig = try await LeadRig.make(audio: true)
        rig.engine.startOnDisplayManually()
        rig.engine.loops = true
        await rig.park(at: 6)
        rig.engine.play(PlaybackRate(-1, 1))
        var positions: [Int64] = []
        try await rig.ticks(60, perFrame: 2) { o in
            positions.append(frame(o.position))
            #expect(!o.stoppedAtEdge)
        }
        #expect(rig.engine.usesAudioClock && rig.engine.rate.isReverse)
        let changes = positions.reduce(into: [Int64]()) { if $0.last != $1 { $0.append($1) } }
        #expect(changes.contains(0) && changes.contains(59) && changes.contains(57), "\(changes)")
        for (a, b) in zip(changes, changes.dropFirst()) { #expect(b == (a + 59) % 60, "\(changes)") }
    }

    @Test func theFramesAfterTheWrapAreDecodedBeforeIt() async throws {
        var rig = try await LeadRig.make(frames: 300)
        rig.engine.startOnDisplayManually()
        rig.engine.loops = true
        rig.engine.playRange = TimeRange(start: fd * 100, end: fd * 160)
        await rig.park(at: 150)
        #expect(!rig.engine.cachedFrame(media: rig.media, pts: fd * 100), "the cache is cold at the loop's beginning")
        rig.engine.play()
        var latest: Int64 = 0
        try await rig.ticks(5) { latest = frame($0.time) }
        #expect(latest >= 150 && latest < 160, "still before the wrap")
        for k in Int64(100)...110 { #expect(rig.engine.cachedFrame(media: rig.media, pts: fd * k), "frame \(k)") }
        // Nothing behind the loop's end is decoded for it.
        #expect(!rig.engine.cachedFrame(media: rig.media, pts: fd * 200))
        // And the wrap shows them without a miss.
        let dropped = rig.engine.stats.droppedFrames
        var frames: [Int64] = []
        try await rig.ticks(14) { frames.append(frame($0.time)) }
        #expect(frames.contains(159) && frames.contains(100) && frames.contains(103), "\(frames)")
        #expect(rig.engine.stats.droppedFrames == dropped)
    }

    @Test func theFramesAfterAReverseWrapAreDecodedBeforeIt() async throws {
        var rig = try await LeadRig.make(frames: 300)
        rig.engine.startOnDisplayManually()
        rig.engine.loops = true
        rig.engine.playRange = TimeRange(start: fd * 100, end: fd * 160)
        await rig.park(at: 108)
        #expect(!rig.engine.cachedFrame(media: rig.media, pts: fd * 159))
        rig.engine.play(PlaybackRate(-1, 1))
        try await rig.ticks(4)
        for k in Int64(150)...159 { #expect(rig.engine.cachedFrame(media: rig.media, pts: fd * k), "frame \(k)") }
    }

    @Test func aPlayStartAtDoubleSpeedShowsTheFramesInOrder() async throws {
        var rig = try await LeadRig.make(frames: 120)
        rig.engine.startOnDisplayManually()
        await rig.park(at: 10)
        rig.engine.play(PlaybackRate(2, 1))
        var frames: [Int64] = [], last: TickOutcome?
        try await rig.ticks(30, perFrame: 2) { frames.append(frame($0.time)); last = $0 }
        #expect(frames.first == 10)
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a + 1 || (b == a && a == 10), "\(frames)") }
        #expect(!rig.clock.rate.isPaused && frames.last! >= 30)
        let o = try #require(last)
        // 83.3 ms at 2x: five frames.
        #expect(frame(o.time) - frame(o.position) == 5, "\(frames)")
    }

    @Test func aLoopShorterThanTheLeadStaysInside() async throws {
        var rig = try await LeadRig.make()
        rig.engine.startOnDisplayManually()
        rig.engine.loops = true
        rig.engine.playRange = TimeRange(start: fd * 20, end: fd * 22)
        await rig.park(at: 20)
        rig.engine.play()
        var frames: [Int64] = [], positions: [Int64] = []
        try await rig.ticks(24) { o in
            frames.append(frame(o.time)); positions.append(frame(o.position))
            #expect(!o.stoppedAtEdge)
        }
        #expect(Set(frames) == [20, 21], "\(frames)")
        #expect(Set(positions) == [20, 21], "\(positions)")
        #expect(!rig.engine.rate.isPaused && !rig.clock.rate.isPaused)
        // Once it runs the two frames alternate.
        for (a, b) in zip(frames.dropFirst(6), frames.dropFirst(7)) { #expect(a != b, "\(frames)") }
    }

    @Test func withoutDisplayTicksATimerStartsTheClockAtThePlayhead() async throws {
        let rig = try await LeadRig.make(audio: true)
        let audio = try #require(rig.audio)
        rig.engine.loop.startsOnDisplay = true
        await rig.park(at: 10)
        rig.engine.play()
        #expect(!audio.isPlaying)
        try await Task.sleep(for: .milliseconds(120))
        #expect(!audio.isPlaying, "it waits for the display link first")
        for _ in 0..<40 where !audio.isPlaying { try await Task.sleep(for: .milliseconds(25)) }
        #expect(audio.isPlaying && audio.lastSeek == fd * 10)
        #expect(rig.engine.usesAudioClock && !rig.engine.rate.isPaused)
        rig.engine.pause()
        #expect(!audio.isPlaying && rig.engine.position == fd * 10)
    }

    // MARK: Pause

    /// Plays at `speed` on a link of `perFrame` ticks per sequence frame, pauses, and returns in frames: where the pause
    /// parked, the frame on the glass at the pause, the newest frame handed to the display (the last one presented),
    /// the clock's frame at the last tick. The presented frames run in one direction through the pause.
    private func pause(speed: Int32, perFrame: Int, audio: Bool = false) async throws -> (parked: Int64, glass: Int64, handed: Int64, clock: Int64) {
        var rig = try await LeadRig.make(frames: 300, audio: audio)
        rig.engine.startOnDisplayManually()
        await rig.park(at: 150)
        rig.engine.play(PlaybackRate(speed, 1))
        var shown: [(at: Double, frame: Int64)] = [], clockFrame: Int64 = 0
        for _ in 0..<(14 * perFrame) {
            let host = rig.host
            try await rig.ticks(1, perFrame: perFrame) { o in
                if o.presented { shown.append((host + 0.0833, frame(o.time))) }
                clockFrame = frame(o.position)
            }
        }
        let glass = try #require(shown.last { $0.at <= rig.host }?.frame)
        let handed = try #require(shown.last?.frame)
        var reported: [Time] = [], pausedInCallback = false
        rig.engine.onPositionChange = { [engine = rig.engine] in reported.append($0); pausedInCallback = engine.rate.isPaused }
        rig.engine.pause()
        let parked = rig.engine.position
        #expect(rig.engine.rate.isPaused)
        #expect(reported.isEmpty || (reported == [parked] && pausedInCallback), "the pause is reported once, paused")
        // Picture, clock and position stay on the parked frame: no tick after the pause presents another one.
        var order = shown.map(\.frame)
        try await rig.ticks(4, perFrame: perFrame) { o in
            #expect(o.time == parked && o.position == parked)
            if o.presented { order.append(frame(o.time)) }
        }
        for (a, b) in zip(order, order.dropFirst()) { #expect(speed > 0 ? b >= a : b <= a, "\(order)") }
        #expect(order.last == frame(parked) && Set(order.drop { $0 != handed }).count == 1, "\(order)")
        #expect(rig.engine.position == parked)
        if audio { #expect(rig.audio?.isPlaying == false) } else { #expect(rig.clock.now() == parked) }
        // Playing on starts there.
        rig.engine.play(PlaybackRate(speed, 1))
        var first: Int64?
        try await rig.ticks(1, perFrame: perFrame) { first = frame($0.time) }
        #expect(first == frame(parked))
        return (frame(parked), glass, handed, clockFrame)
    }

    @Test func aPauseParksOnTheLastFrameHandedToTheDisplay() async throws {
        let p = try await pause(speed: 1, perFrame: 1)
        #expect(p.parked == p.handed, "\(p)")
        #expect(p.parked - p.glass == 2, "\(p)")
    }

    @Test func aPauseAtDoubleSpeedParksOnTheLastFrameHandedToTheDisplay() async throws {
        let p = try await pause(speed: 2, perFrame: 2)
        #expect(p.parked == p.handed, "\(p)")
        #expect(p.parked - p.glass == 4, "\(p)")
    }

    @Test func aPauseAtFourTimesSpeedParksOnTheLastFrameHandedToTheDisplay() async throws {
        let p = try await pause(speed: 4, perFrame: 4)
        #expect(p.parked == p.handed, "\(p)")
        #expect(p.parked - p.glass == 9, "\(p)")
    }

    @Test func aPauseInReverseParksOnTheLastFrameHandedToTheDisplay() async throws {
        let p = try await pause(speed: -1, perFrame: 1)
        #expect(p.parked == p.handed, "\(p)")
        #expect(p.glass - p.parked == 2, "\(p)")
    }

    @Test func aPauseOnTheAudioClockParksOnTheLastFrameHandedToTheDisplay() async throws {
        let p = try await pause(speed: 1, perFrame: 1, audio: true)
        #expect(p.parked == p.handed, "\(p)")
        #expect(p.parked - p.glass == 2, "\(p)")
    }

    @Test func aPauseNearTheEndStaysThereAndIsReportedPaused() async throws {
        var rig = try await LeadRig.make()
        rig.engine.startOnDisplayManually()
        await rig.park(at: 48)
        rig.engine.play()
        var last = Time.zero
        try await rig.ticks(12) { o in if o.presented { last = o.time } }
        var seen: [(Time, Bool)] = []
        rig.engine.onPositionChange = { [engine = rig.engine] in seen.append(($0, engine.rate.isPaused)) }
        rig.engine.pause()
        let at = rig.engine.position
        #expect(at == last && frame(at) >= 57 && frame(at) <= 59, "\(frame(at))")
        // A host takes a position near the end of a playing engine for "reached the end": this one comes paused.
        #expect(seen.allSatisfy { $0.0 == at && $0.1 }, "\(seen)")
        try await rig.ticks(4) { o in #expect(o.time == at && o.position == at && !o.stoppedAtEdge) }
        #expect(rig.engine.position == at)
    }

    @Test(.timeLimit(.minutes(1))) func aPauseDoesNotWaitForATickThatComposites() async throws {
        let gate = TickGate()
        var rig = try await LeadRig.make(resolver: { GatedResolver(base: $0, gate: gate) })
        rig.engine.startOnDisplayManually()
        await rig.park(at: 10)
        rig.engine.play()
        var last = Time.zero
        try await rig.ticks(12) { o in if o.presented { last = o.time } }
        let loop = rig.engine.loop, host = rig.host
        let late = Mutex<TickOutcome?>(nil)
        gate.armed.store(true, ordering: .relaxed)
        Thread.detachNewThread {
            let o = loop.tick(presentAt: host + 0.0833, hostNow: host)
            late.withLock { $0 = o }
            gate.done.signal()
        }
        let entered = gate.waitUntilEntered()
        try #require(entered, "the tick composites")
        // The tick holds the GPU: the pause returns all the same, parked on the last frame presented.
        rig.engine.pause()
        let at = rig.engine.position
        #expect(rig.engine.rate.isPaused && rig.clock.rate.isPaused && rig.clock.now() == at && at == last)
        gate.finish()
        // That tick had not handed its frame over yet: it presents nothing after the pause.
        #expect(late.withLock { $0 } == nil)
        try await rig.ticks(4) { o in #expect(o.time == at && o.position == at) }
        #expect(rig.engine.position == at && rig.clock.now() == at)
    }

    /// Plays from frame 150 of 600 (a cut at 300), then the clock runs `frames` on at once, into the second clip: the
    /// next tick has no picture of it and holds the last one. Returns the rig, the last frame presented and that
    /// tick's outcome.
    private func heldTick(clockRunsOn frames: Int64) async throws -> (rig: LeadRig, last: Time, held: TickOutcome) {
        var rig = try await LeadRig.make(frames: 600, cutInHalf: true)
        rig.engine.startOnDisplayManually()
        await rig.park(at: 150)
        rig.engine.play()
        var last = Time.zero
        try await rig.ticks(8) { o in if o.presented { last = o.time } }
        rig.clock.advance(by: fd * frames)
        let held = try #require(rig.engine.tick(presentAt: rig.host + 0.0833, hostNow: rig.host))
        try #require(!held.presented, "the tick holds the last picture")
        return (rig, last, held)
    }

    @Test func aPauseAfterAnEdgeStopThatHeldThePictureStaysOnTheLastFrame() async throws {
        // Fast into the end of heavy media: the clock passes the end while the last frame is not decoded yet.
        var (rig, last, held) = try await heldTick(clockRunsOn: 1000)
        #expect(held.stoppedAtEdge && frame(last) < 200)
        // The host stops the engine when it hears of the edge.
        var reported: [Time] = []
        rig.engine.onPositionChange = { reported.append($0) }
        rig.engine.pause()
        #expect(rig.engine.position == fd * 599 && rig.clock.now() == fd * 599, "\(frame(rig.engine.position))")
        #expect(reported.allSatisfy { $0 == fd * 599 }, "\(reported.map(frame))")
        await rig.engine.waitForDecodes()
        try await rig.ticks(3) { o in #expect(o.time == fd * 599 && o.position == fd * 599) }
    }

    @Test func aPauseWhileThePictureIsHeldStaysAtTheClock() async throws {
        // Every layer cold while playing: the picture holds, the clock (sound, playhead) runs on.
        var (rig, last, held) = try await heldTick(clockRunsOn: 200)
        #expect(!held.stoppedAtEdge && held.playing)
        let clockFrame = frame(rig.clock.now())
        rig.engine.pause()
        let at = rig.engine.position
        // Not back on the last presented frame, 200 frames ago: where the sound is. The picture goes forward.
        #expect(frame(at) == clockFrame && at > last && rig.clock.now() == at, "\(frame(at)) \(clockFrame) \(frame(last))")
        await rig.engine.waitForDecodes()
        try await rig.ticks(3) { o in #expect(o.time == at && o.position == at) }
    }

    @Test func theParkPositionIsTheHandedFrameUnlessTheClockRanAwayFromIt() {
        let one = PlaybackRate(1, 1), back = PlaybackRate(-1, 1), four = PlaybackRate(4, 1)
        func park(_ handed: Int64?, clock: Int64, _ rate: PlaybackRate, loop: TimeRange? = nil) -> Int64 {
            frame(DisplayLead.parkPosition(handed: handed.map { fd * $0 }, clock: fd * clock, rate: rate, loop: loop))
        }
        // The picture leads the clock: the handed frame.
        #expect(park(103, clock: 100, one) == 103)
        #expect(park(97, clock: 100, back) == 97)
        #expect(park(118, clock: 100, four) == 118)
        #expect(park(nil, clock: 100, one) == 100)
        // The clock is past it by less than the largest lead (150 ms of host time): still the handed frame.
        #expect(park(100, clock: 104, one) == 100)
        #expect(park(100, clock: 96, back) == 100)
        #expect(park(100, clock: 117, four) == 100)
        // The clock ran on through a hold: the clock frame, which is ahead in play direction.
        #expect(park(100, clock: 105, one) == 105)
        #expect(park(100, clock: 95, back) == 95)
        #expect(park(100, clock: 119, four) == 119)
        // Looping, the picture is past the wrap before the clock: that is its lead, not a hold.
        let loop = TimeRange(start: fd * 10, duration: fd * 50)
        #expect(park(12, clock: 58, one, loop: loop) == 12)
        #expect(park(58, clock: 11, back, loop: loop) == 58)
        #expect(park(20, clock: 40, one, loop: loop) == 40)
    }

    @Test func theLoopWrapMovesTheClockOutsideTheStateLock() async throws {
        let probe = Mutex<ProbeClock?>(nil)
        var rig = try await LeadRig.make(clock: { let c = ProbeClock($0); probe.withLock { $0 = c }; return c })
        rig.engine.startOnDisplayManually()
        rig.engine.loops = true
        await rig.park(at: 52)
        rig.engine.play()
        try await rig.ticks(3)
        // From here on the only seek is the wrap. A seek made under the state lock could not take it again (the audio
        // clock restarts its output in there: nothing else may wait for that).
        let seeks = Atomic<Int>(0)
        let loop = rig.engine.loop
        let clock = try #require(probe.withLock { $0 })
        clock.onSeek.withLock { $0 = { _ = loop.loops; seeks.wrappingAdd(1, ordering: .relaxed) } }
        try await rig.ticks(12)
        clock.onSeek.withLock { $0 = nil }
        #expect(seeks.load(ordering: .relaxed) == 1)
    }
}
