import Foundation
import Metal
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

/// While playing, the frame a tick picks is the one for the time it reaches the glass: clock + display lead x rate.
@Suite struct DisplayLeadTests {
    let fd = Time(1, 30)
    let one = PlaybackRate(1, 1)
    /// 2.25 frames at 30 fps.
    let lead = Time(75_000, 1_000_000)

    private func frame(_ t: Time) -> Int64 { t.frameIndex(frameDuration: fd) }

    /// A lead that already ran through its ramp (far from where playing began).
    private func settled(rate: PlaybackRate, at now: Time) -> DisplayLead {
        var l = DisplayLead(); l.enabled = true
        _ = l.position(clock: rate.isReverse ? now + Time(100, 1) : now - Time(100, 1), rate: rate, hostLead: lead,
                       frameDuration: fd)
        return l
    }

    // MARK: Host lead

    @Test func hostLeadIsTheDistanceToThePresentationTime() {
        #expect(DisplayLead.hostLead(presentAt: 10.075, hostNow: 10) == Time(75_000, 1_000_000))
        #expect(DisplayLead.hostLead(presentAt: 100.0833334, hostNow: 100) == Time(83_333, 1_000_000))
    }

    @Test func missingOrBadTimestampAddsNothing() {
        #expect(DisplayLead.hostLead(presentAt: nil, hostNow: 10) == .zero)
        #expect(DisplayLead.hostLead(presentAt: 0, hostNow: 10) == .zero)
        #expect(DisplayLead.hostLead(presentAt: 9.9, hostNow: 10) == .zero)
        #expect(DisplayLead.hostLead(presentAt: .nan, hostNow: 10) == .zero)
        #expect(DisplayLead.hostLead(presentAt: .infinity, hostNow: 10) == .zero)
        #expect(DisplayLead.hostLead(presentAt: 10.05, hostNow: .nan) == .zero)
    }

    @Test func aFarTimestampIsClamped() {
        #expect(DisplayLead.hostLead(presentAt: 15, hostNow: 10) == Time(150_000, 1_000_000))
        #expect(DisplayLead.hostLead(presentAt: 1e300, hostNow: 10) == Time(150_000, 1_000_000))
    }

    // MARK: Position

    @Test func forwardLeadsByTheHostLead() {
        let now = Time(200, 1) + Time(1, 60)
        var l = settled(rate: one, at: now)
        let p = l.position(clock: now, rate: one, hostLead: lead, frameDuration: fd)
        #expect(p == now + lead)
        #expect(frame(p) == frame(now) + 2)
    }

    @Test func reverseLeadsBackwards() {
        let r = PlaybackRate(-1, 1)
        let now = Time(200, 1) + Time(1, 60)
        var l = settled(rate: r, at: now)
        let p = l.position(clock: now, rate: r, hostLead: lead, frameDuration: fd)
        #expect(p == now - lead)
        #expect(frame(p) == frame(now) - 2)        // 16.7 ms into the frame, 75 ms back
    }

    @Test func leadScalesWithTheRate() {
        let now = Time(200, 1)
        let rates: [PlaybackRate] = [PlaybackRate(2, 1), PlaybackRate(1, 2), PlaybackRate(-2, 1), PlaybackRate(8, 1)]
        let micros: [Int64] = [150_000, 37_500, -150_000, 600_000]
        for (rate, us) in zip(rates, micros) {
            var l = settled(rate: rate, at: now)
            let p: Time = l.position(clock: now, rate: rate, hostLead: lead, frameDuration: fd)
            let d: Time = p - now
            #expect(d == Time(us, 1_000_000))
        }
    }

    @Test func pausedAddsNothing() {
        var l = DisplayLead(); l.enabled = true
        let now = Time(7, 1) + Time(1, 90)
        #expect(l.position(clock: now, rate: .zero, hostLead: lead, frameDuration: fd) == now)
        // Also right after playing: a paused tick shows the exact frame at the clock.
        var s = settled(rate: one, at: now)
        #expect(s.position(clock: now, rate: .zero, hostLead: lead, frameDuration: fd) == now)
    }

    @Test func noTimestampKeepsTheClockPosition() {
        var l = settled(rate: one, at: Time(50, 1))
        #expect(l.position(clock: Time(50, 1), rate: one, hostLead: nil, frameDuration: fd) == Time(50, 1))
    }

    @Test func disabledKeepsTheClockPosition() {
        var l = settled(rate: one, at: Time(50, 1)); l.enabled = false
        #expect(l.position(clock: Time(50, 1), rate: one, hostLead: lead, frameDuration: fd) == Time(50, 1))
    }

    // MARK: Start, seek

    @Test func playStartShowsThePlayheadFrameAndRampsIn() {
        var l = DisplayLead(); l.enabled = true
        let start = fd * 100
        // First playing tick, a moment after the clock started.
        let first = l.position(clock: start + Time(1, 1000), rate: one, hostLead: lead, frameDuration: fd)
        #expect(first == start + Time(1, 1000))
        #expect(frame(first) == 100)
        // 30 Hz ticks: the picture catches up one frame at a time, never steps back, and ends 2 frames ahead.
        var last = frame(first), steps: [Int64] = []
        for k in 1...40 {
            let now = start + Time(1, 1000) + fd * Int64(k)
            let p = l.position(clock: now, rate: one, hostLead: lead, frameDuration: fd)
            steps.append(frame(p) - last); last = frame(p)
            #expect(p - now <= lead)
        }
        #expect(steps.allSatisfy { $0 == 1 || $0 == 2 })
        #expect(steps.filter { $0 == 2 }.count == 2)
        #expect(last == 100 + 40 + 2)
        // Fully in after 8 x lead of travel (0.6 s).
        var m = DisplayLead(); m.enabled = true
        _ = m.position(clock: start, rate: one, hostLead: lead, frameDuration: fd)
        #expect(m.position(clock: start + Time(3, 10), rate: one, hostLead: lead, frameDuration: fd) == start + Time(3, 10) + Time(37_500, 1_000_000))
        #expect(m.position(clock: start + Time(6, 10), rate: one, hostLead: lead, frameDuration: fd) == start + Time(6, 10) + lead)
    }

    @Test func resetStartsTheRampAgain() {
        var l = settled(rate: one, at: Time(50, 1))
        l.reset()
        #expect(l.position(clock: Time(50, 1), rate: one, hostLead: lead, frameDuration: fd) == Time(50, 1))
    }

    @Test func aSeekWhilePlayingKeepsTheLead() {
        // Loop wrap or a click in the ruler during playback: the frame for the glass, no new ramp.
        var l = settled(rate: one, at: Time(50, 1))
        let target = fd * 300
        #expect(l.position(clock: target, rate: one, hostLead: lead, frameDuration: fd) == target + lead)
        #expect(l.position(clock: target + fd, rate: one, hostLead: lead, frameDuration: fd) == target + fd + lead)
    }

    @Test func aLateTickReusesTheLastLead() {
        var l = settled(rate: one, at: Time(50, 1))
        #expect(l.position(clock: Time(50, 1), rate: one, hostLead: lead, frameDuration: fd) == Time(50, 1) + lead)
        // presentAt <= host now: `hostLead` is zero.
        #expect(l.position(clock: Time(50, 1) + fd, rate: one, hostLead: .zero, frameDuration: fd) == Time(50, 1) + fd + lead)
        // Before any usable lead there is nothing to reuse.
        var fresh = DisplayLead(); fresh.enabled = true
        _ = fresh.position(clock: Time(1, 1), rate: one, hostLead: .zero, frameDuration: fd)
        #expect(fresh.position(clock: Time(9, 1), rate: one, hostLead: .zero, frameDuration: fd) == Time(9, 1))
    }

    @Test func slowingDownNeverStepsThePictureBack() {
        // Shuttle 2x to 1x: the wanted lead halves; the applied one follows by 1/8 of the distance played.
        let two = PlaybackRate(2, 1)
        var now = Time(50, 1) + Time(1, 60)
        var l = settled(rate: two, at: now)
        var lastFrame = frame(l.position(clock: now, rate: two, hostLead: lead, frameDuration: fd))
        var lastLead = Time(150_000, 1_000_000)
        for _ in 0..<40 {
            now = now + fd
            let p: Time = l.position(clock: now, rate: one, hostLead: lead, frameDuration: fd)
            let d: Time = p - now
            #expect(frame(p) >= lastFrame)
            #expect(d <= lastLead && d >= lead)
            lastFrame = frame(p); lastLead = d
        }
        #expect(lastLead == lead)
    }

    @Test func aDirectionChangeRampsAgain() {
        var l = settled(rate: one, at: Time(50, 1))
        let r = PlaybackRate(-1, 1)
        #expect(l.position(clock: Time(50, 1), rate: r, hostLead: lead, frameDuration: fd) == Time(50, 1))
        #expect(l.position(clock: Time(49, 1), rate: r, hostLead: lead, frameDuration: fd) == Time(49, 1) - lead)
    }

    // MARK: Bounds

    @Test func neverLeadsPastTheEndOfThePlayRange() {
        var l = settled(rate: one, at: Time(9, 1))
        l.bounds = TimeRange(start: Time(5, 1), end: Time(10, 1))
        let lastInside = frame(Time(10, 1)) - 1
        var now = Time(10, 1) - fd * 6 + Time(1, 60)
        while now < Time(10, 1) {
            let p = l.position(clock: now, rate: one, hostLead: lead, frameDuration: fd)
            #expect(frame(p) <= lastInside)
            #expect(frame(p) >= frame(now))
            now = now + fd
        }
        // Playing on past the range (no stop there): leads as usual.
        #expect(l.position(clock: Time(11, 1), rate: one, hostLead: lead, frameDuration: fd) == Time(11, 1) + lead)
    }

    @Test func reverseNeverLeadsBeforeTheStartOfThePlayRange() {
        let r = PlaybackRate(-1, 1)
        var l = settled(rate: r, at: Time(6, 1))
        l.bounds = TimeRange(start: Time(5, 1), end: Time(10, 1))
        var now = Time(5, 1) + fd * 6 + Time(1, 60)
        while now >= Time(5, 1) {
            let p = l.position(clock: now, rate: r, hostLead: lead, frameDuration: fd)
            #expect(p >= Time(5, 1))
            #expect(p <= now)
            now = now - fd
        }
    }

    @Test func loopWrapKeepsTheLead() {
        var l = settled(rate: one, at: Time(9, 1))
        l.bounds = TimeRange(start: Time(5, 1), end: Time(10, 1))
        // The host seeks to the In point and plays on: the lead stays (short loops do not ramp on every pass).
        #expect(l.position(clock: Time(5, 1), rate: one, hostLead: lead, frameDuration: fd) == Time(5, 1) + lead)
    }

    // MARK: No drift

    @Test func theLeadDoesNotAccumulate() {
        // An hour of 30 Hz ticks on a nanosecond clock: the offset is the lead on every tick, the timescale stays bounded.
        var l = DisplayLead(); l.enabled = true
        let tick = Time(33_333_333, 1_000_000_000)
        var now = Time(1, 1_000_000_000)
        _ = l.position(clock: now, rate: one, hostLead: lead, frameDuration: fd)
        for k in 0..<108_000 {
            now = now + tick
            let p = l.position(clock: now, rate: one, hostLead: lead, frameDuration: fd)
            if k > 30 { #expect(p - now == lead) }
            #expect(p.timescale <= 1_000_000_000)
        }
    }

    // MARK: Engine

    @MainActor private func makeEngine(frames: Int64 = 60) async throws -> (PlaybackEngine, ManualClock) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec(); spec.frameCount = Int(frames); spec.frameDuration = TestClipSpec.fps(30)
        let file = try await TestClipWriter.write(spec)
        let a = UUID(), clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: file)]),
                                        clock: clock)
        engine.waitsForStartFrame = false
        engine.locksFramePhase = false
        engine.loop.leadsDisplay = true
        let clip = Clip(name: "c", media: a, kind: .video, source: TimeRange(start: .zero, duration: fd * frames), start: .zero,
                        mediaDuration: fd * frames)
        engine.setTimeline(Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                                    tracks: [Track(kind: .video, clips: [clip])]))
        engine.seek(to: .zero)
        await engine.waitForDecodes()
        _ = engine.tick()
        return (engine, clock)
    }

    @MainActor @Test func playingPicksTheFrameForTheGlassAndPublishesTheClock() async throws {
        let (engine, clock) = try await makeEngine()
        engine.play()
        // First playing tick: the playhead frame, no skip.
        clock.advance(by: Time(1, 60))
        let first = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
        #expect(first.time == .zero && first.position == .zero)
        var o = first
        for _ in 0..<30 {
            clock.advance(by: fd)
            o = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
            await engine.waitForDecodes()
            let atClock: Time = fd * clock.now().frameIndex(frameDuration: fd)
            #expect(o.position == atClock)
            if o.presented { #expect(engine.position == o.position) }
        }
        #expect(o.time == o.position + fd * 2, "the picture leads the clock by the display lead")
        // No timestamp (headless): the frame at the clock, as before.
        clock.advance(by: fd)
        let plain = try #require(engine.loop.tick())
        #expect(plain.time == plain.position)
        // Pause: playhead and picture are the clock frame.
        let at: Time = fd * clock.now().frameIndex(frameDuration: fd)
        engine.pause()
        let paused = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
        #expect(paused.time == at && paused.position == at && clock.now() == at)
    }

    @MainActor @Test func seekAndStepShowTheExactFrame() async throws {
        let (engine, _) = try await makeEngine()
        engine.seek(to: fd * 20)
        await engine.waitForDecodes()
        var o = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
        #expect(o.time == fd * 20 && o.position == fd * 20)
        engine.step(1)
        await engine.waitForDecodes()
        o = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
        #expect(o.time == fd * 21 && o.position == fd * 21)
        engine.step(-1)
        await engine.waitForDecodes()
        o = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
        #expect(o.time == fd * 20 && o.position == fd * 20)
    }

    @MainActor @Test func neverPicksAFrameBeyondTheEnd() async throws {
        let (engine, clock) = try await makeEngine()
        engine.seek(to: fd * 30)
        await engine.waitForDecodes()
        _ = engine.tick()
        engine.play()
        clock.advance(by: Time(1, 60))
        var stopped = false, led = false
        for _ in 0..<40 where !stopped {
            let o = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
            await engine.waitForDecodes()
            #expect(o.time <= fd * 59)
            #expect(o.position <= fd * 59)
            if o.time > o.position { led = true }
            stopped = o.stoppedAtEdge
            clock.advance(by: fd)
        }
        #expect(stopped && led)
        #expect(engine.position == fd * 59)
        #expect(engine.rate.isPaused)
    }

    /// What the host does with a published position (`EditorSession.enginePositionChanged`): stop or wrap by
    /// `PlaybackBounds`. Returns a counter of wraps.
    @MainActor private func hostLoop(_ engine: PlaybackEngine, bounds: PlaybackBounds, frames: Int64) -> WrapCount {
        let wraps = WrapCount()
        let fd = fd
        engine.onPositionChange = { [weak engine] t in
            guard let engine else { return }
            let rate = engine.rate
            if case .wrap(let to) = bounds.action(at: t, rate: rate, frameDuration: fd, duration: fd * frames) {
                wraps.count += 1
                engine.seek(to: to); engine.play(rate)
            }
        }
        return wraps
    }

    @MainActor @Test func loopWrapsAtTheEndWhileThePictureHolds() async throws {
        // The picked frame reaches the last frame before the clock does and holds: the clock position must still be
        // published, or the host never sees the end and the edge stop pauses a looping sequence.
        let (engine, clock) = try await makeEngine()
        let wraps = hostLoop(engine, bounds: PlaybackBounds(loop: true), frames: 60)
        engine.seek(to: fd * 45)
        await engine.waitForDecodes()
        _ = engine.tick()
        engine.play()
        clock.advance(by: Time(1, 60))
        var held = false
        for _ in 0..<30 {
            let o = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
            await engine.waitForDecodes()
            #expect(!o.stoppedAtEdge)
            #expect(o.time <= fd * 59)
            if !o.presented, o.time == fd * 59, wraps.count == 0 { held = true }
            clock.advance(by: fd)
        }
        #expect(held, "the picture waited on the last frame")
        #expect(wraps.count == 1)
        #expect(!engine.rate.isPaused)
        #expect(engine.position > .zero && engine.position < fd * 20)
    }

    @MainActor @Test func reverseLoopWrapsAtTheStart() async throws {
        let (engine, clock) = try await makeEngine()
        let wraps = hostLoop(engine, bounds: PlaybackBounds(loop: true), frames: 60)
        engine.seek(to: fd * 12)
        await engine.waitForDecodes()
        _ = engine.tick()
        engine.play(PlaybackRate(-1, 1))
        clock.advance(by: Time(1, 60))
        for _ in 0..<25 {
            let o = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
            await engine.waitForDecodes()
            #expect(!o.stoppedAtEdge)
            #expect(o.time >= .zero)
            clock.advance(by: fd)
        }
        #expect(wraps.count == 1)
        #expect(engine.rate.isReverse)
        #expect(engine.position > fd * 40)
    }

    @MainActor @Test func theClockPositionIsPublishedUpToTheEnd() async throws {
        // Playhead and timecode do not freeze where the picture starts to hold.
        let (engine, clock) = try await makeEngine()
        engine.seek(to: fd * 50)
        await engine.waitForDecodes()
        _ = engine.tick()
        var seen: [Int64] = []
        let fd = fd
        engine.onPositionChange = { seen.append($0.frameIndex(frameDuration: fd)) }
        engine.play()
        clock.advance(by: Time(1, 60))
        for _ in 0..<12 {
            _ = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
            await engine.waitForDecodes()
            clock.advance(by: fd)
        }
        #expect(seen.contains(57) && seen.contains(58) && seen.contains(59))
        #expect(engine.rate.isPaused && engine.position == fd * 59)
    }

    @MainActor @Test func playRangeHoldsTheLastFrameInside() async throws {
        let (engine, clock) = try await makeEngine()
        let range = TimeRange(start: fd * 10, end: fd * 40)
        engine.playRange = range
        let wraps = hostLoop(engine, bounds: PlaybackBounds(loop: true, range: range), frames: 60)
        engine.seek(to: fd * 20)
        await engine.waitForDecodes()
        _ = engine.tick()
        engine.play()
        clock.advance(by: Time(1, 60))
        var held = false
        // Past the wrap point: the picture never leaves the range, before or after the host wrapped to its start.
        for _ in 0..<40 {
            let o = try #require(engine.tick(presentAt: 100.075, hostNow: 100))
            await engine.waitForDecodes()
            #expect(o.time <= fd * 39)
            #expect(o.position <= fd * 39)
            if wraps.count == 0, o.time == fd * 39, o.position < fd * 39 { held = true }
            if wraps.count > 0 { #expect(o.time >= fd * 10) }
            clock.advance(by: fd)
        }
        #expect(held && wraps.count == 1)
        #expect(!engine.rate.isPaused)
        #expect(engine.position >= fd * 10 && engine.position < fd * 39)
    }

    // MARK: Probe

    @Test func probeReportsPictureAgainstSound() {
        // 30 fps; frames reach the glass 80 ms after the tick read the clock.
        let f = 1.0 / 30
        // Not led: the frame at the clock is shown 80 ms late.
        func samples(ledBy lead: Double) -> [PresentProbe.Sample] {
            var out: [PresentProbe.Sample] = []
            for k in 0..<10 {
                let at: Double = Double(k) * f
                let glass: Double = 1.08 + at
                out.append(PresentProbe.Sample(time: at + lead, target: glass, presented: glass, tickStart: 1 + at,
                                               tickDuration: 0.001, clock: at + f / 2))
            }
            return out
        }
        let late = samples(ledBy: 0)
        let a = PresentProbe.summarize(late, frameDuration: f)
        #expect(a.avOffsets.count == 10)
        #expect(a.avOffsets.allSatisfy { abs($0 + 80) < 0.001 })
        // Led by 80 ms: the frame is centered on its time.
        let led = samples(ledBy: 0.08)
        #expect(PresentProbe.summarize(led, frameDuration: f).avOffsets.allSatisfy { abs($0) < 0.001 })
        // Samples without a clock position take no part.
        #expect(PresentProbe.summarize([.init(time: 0, target: 1, presented: 1)], frameDuration: f).avOffsets.isEmpty)
    }

    // MARK: Play start timed to the display (pure)

    private func seconds(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
    private func micros(_ s: Double) -> Time { Time(Int64((s * 1_000_000).rounded()), 1_000_000) }

    /// A display link ticking every `interval` s whose frames are shown `ahead` s after the tick; the clock is a host
    /// clock started by the main actor at the first tick at or after the play start's host time (`late` s later).
    /// Returns the position picked per tick.
    private func run(start: Time, rate: PlaybackRate, firstTick: Double, interval: Double = 1.0 / 30, ahead: Double = 0.0833,
                     late: Double = 0, ticks: Int = 30) -> (picked: [Time], startedAt: Double?) {
        var ps = PlayStart(start: start, rate: rate, token: 1)
        var l = DisplayLead(); l.enabled = true
        var began: (host: Double, at: Time)?
        var out: [Time] = []
        let speed = Double(abs(rate.num)) / Double(rate.den)
        for k in 0..<ticks {
            let h = firstTick + Double(k) * interval, p = h + ahead
            if began == nil, let hs = ps.hostStart, hs + late <= h {
                began = (h, ps.clockPosition(atHost: h))
                l.prime(floor: ps.lastLed, hostLead: ps.lastHostLead)
            }
            if let b = began {
                let now = b.at + scaled(micros(h - b.host), by: rate)
                out.append(l.position(clock: now, rate: rate, hostLead: DisplayLead.hostLead(presentAt: p, hostNow: h), frameDuration: fd))
            } else {
                switch ps.tick(presentAt: p, hostNow: h, frameDuration: fd, linkInterval: 1 / (30 * max(1, speed))) {
                case .led(let v, _): out.append(v)
                case .hold, .startNow: out.append(start)
                }
            }
        }
        return (out, began?.host)
    }

    @Test func playStartShowsEveryFrameInOrder() {
        // Whatever the phase of the first tick: the start frame, then every next frame, one per tick.
        for phase in [0.0, 0.004, 0.011, 0.019, 0.027, 0.0329] {
            let r = run(start: Time(10, 1), rate: one, firstTick: 100 + phase)
            let frames = r.picked.map(frame)
            #expect(frames.first == 300)
            for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a + 1 || (b == a && a == 300), "phase \(phase): \(frames)") }
            #expect(frames.last! >= 300 + 25)
            #expect(r.startedAt != nil)
        }
    }

    @Test func playStartLocksThePhaseMidFrame() {
        // Every led frame is picked in the middle of its time, for every phase of the first tick: the same residual
        // picture-to-clock offset on every play start.
        for phase in [0.0, 0.004, 0.011, 0.019, 0.027, 0.0329] {
            let r = run(start: Time(10, 1), rate: one, firstTick: 100 + phase)
            for p in r.picked where p > Time(10, 1) {
                let inFrame: Time = p - fd * frame(p)
                #expect(abs(seconds(inFrame) - seconds(fd) / 2) < 0.0005, "phase \(phase): \(seconds(inFrame))")
            }
        }
    }

    @Test func playStartHoldsThePictureWhenTheClockStartsLate() {
        // The main actor starts the clock 50 ms late: the picture went on by the display; no frame is shown out of
        // order and none is skipped.
        let r = run(start: Time(10, 1), rate: one, firstTick: 100, late: 0.05)
        let frames = r.picked.map(frame)
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a + 1 || b == a, "\(frames)") }
        #expect(frames.last! >= 300 + 20)
    }

    @Test func playStartInReverse() {
        let rev = PlaybackRate(-1, 1)
        for phase in [0.0, 0.009, 0.021] {
            let frames = run(start: Time(10, 1), rate: rev, firstTick: 100 + phase).picked.map(frame)
            #expect(frames.first == 300)
            for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a - 1 || (b == a && a == 300), "phase \(phase): \(frames)") }
            #expect(frames.last! <= 300 - 25)
        }
    }

    @Test func playStartOnALinkAtTwiceTheFrameRate() {
        // 60 Hz ticks for 30 fps: two ticks per frame, at 1/4 and 3/4 of it.
        let r = run(start: Time(10, 1), rate: one, firstTick: 100.003, interval: 1.0 / 60, ticks: 40)
        let frames = r.picked.map(frame)
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a + 1 || b == a, "\(frames)") }
        #expect(frames.last! >= 300 + 15)
        for p in r.picked where p > Time(10, 1) + fd {
            let inFrame = seconds(p - fd * frame(p)) / seconds(fd)
            #expect(abs(inFrame - 0.25) < 0.02 || abs(inFrame - 0.75) < 0.02, "\(inFrame)")
        }
    }

    @Test func playStartWaitsForASteadyLinkAtMostFourTicks() {
        // The link still runs at 120 Hz (it was idle): the start is set by the fourth tick anyway.
        var ps = PlayStart(start: Time(10, 1), rate: one, token: 1)
        var anchoredAt: Int?
        for k in 0..<6 {
            let h = 100 + Double(k) / 120
            if case .led(_, let anchored) = ps.tick(presentAt: h + 0.03, hostNow: h, frameDuration: fd, linkInterval: 1.0 / 30), anchored {
                anchoredAt = k
            }
        }
        #expect(anchoredAt == 3)
        #expect(ps.hostStart != nil)
    }

    @Test func playStartWithoutATimestampStartsAtOnce() {
        var ps = PlayStart(start: Time(10, 1), rate: one, token: 1)
        #expect(ps.tick(presentAt: nil, hostNow: 100, frameDuration: fd, linkInterval: 1.0 / 30) == .startNow)
        #expect(ps.clockPosition(atHost: 100.5) == Time(10, 1))
    }

    @Test func theClockNeverStartsBeforeTheStartPosition() throws {
        var ps = PlayStart(start: Time(10, 1), rate: one, token: 1)
        _ = ps.tick(presentAt: 100.0833, hostNow: 100, frameDuration: fd, linkInterval: 1.0 / 30)
        _ = ps.tick(presentAt: 100.1166, hostNow: 100.0333, frameDuration: fd, linkInterval: 1.0 / 30)
        let hs = try #require(ps.hostStart)
        #expect(hs > 100.0333 && hs < 100.1166)
        #expect(ps.clockPosition(atHost: hs - 0.02) == Time(10, 1))
        #expect(abs(seconds(ps.clockPosition(atHost: hs + 0.02)) - 10.02) < 0.00001)
    }

    @Test func aPrimedLeadIsFullAtOnceAndNeverStepsBelowItsFloor() {
        var l = DisplayLead(); l.enabled = true
        l.prime(floor: Time(10, 1) + fd * 3, hostLead: .zero)
        // Full lead on the first tick (no ramp) but not below the frame the pre-roll already showed.
        #expect(l.position(clock: Time(10, 1), rate: one, hostLead: lead, frameDuration: fd) == Time(10, 1) + fd * 3)
        let later = Time(10, 1) + fd * 2
        #expect(l.position(clock: later, rate: one, hostLead: lead, frameDuration: fd) == later + lead)
        #expect(l.position(clock: later + fd, rate: one, hostLead: lead, frameDuration: fd) == later + fd + lead)
    }

    // MARK: Loop (pure)

    @Test func wrappedPositionsStayInsideTheLoop() {
        let r = TimeRange(start: Time(5, 1), end: Time(10, 1))
        #expect(DisplayLead.wrapped(Time(7, 1), in: r) == Time(7, 1))
        #expect(DisplayLead.wrapped(Time(10, 1), in: r) == Time(5, 1))
        #expect(DisplayLead.wrapped(Time(10, 1) + lead, in: r) == Time(5, 1) + lead)
        #expect(DisplayLead.wrapped(Time(5, 1) - lead, in: r) == Time(10, 1) - lead)
        // Far outside: never outside the loop.
        let high = DisplayLead.wrapped(Time(100, 1), in: r), low = DisplayLead.wrapped(Time(-100, 1), in: r)
        #expect(high >= Time(5, 1) && high < Time(10, 1))
        #expect(low >= Time(5, 1) && low < Time(10, 1))
    }

    @Test func aLoopingLeadIsNotHeldAtTheEnd() {
        var l = settled(rate: one, at: Time(9, 1))
        l.bounds = TimeRange(start: Time(5, 1), end: Time(10, 1))
        l.loops = true
        let now = Time(10, 1) - Time(1, 60)
        let p = l.position(clock: now, rate: one, hostLead: lead, frameDuration: fd)
        #expect(p == now + lead)
        #expect(DisplayLead.wrapped(p, in: l.bounds!) == Time(5, 1) + lead - Time(1, 60))
    }

    // MARK: Play start, loop and pause (engine)

    /// Ticks as a 30 Hz display link does (frames shown 83.3 ms after the tick); the clock advances with host time once it runs.
    @MainActor private func linkTicks(_ engine: PlaybackEngine, _ clock: ManualClock, count: Int, host: inout Double,
                                      each: (TickOutcome) -> Void) async throws {
        for _ in 0..<count {
            let o = try #require(engine.tick(presentAt: host + 0.0833, hostNow: host))
            await engine.waitForDecodes()
            each(o)
            host += 1.0 / 30
            if !clock.rate.isPaused { clock.advance(by: fd) }
        }
    }

    @MainActor private func parked(_ engine: PlaybackEngine, at f: Int64) async throws {
        engine.seek(to: fd * f)
        await engine.waitForDecodes()
        _ = engine.tick()
    }

    @MainActor @Test func playStartShowsEveryFrameFromTheStartPosition() async throws {
        let (engine, clock) = try await makeEngine()
        engine.startOnDisplayManually()
        try await parked(engine, at: 10)
        engine.play()
        #expect(clock.rate.isPaused, "the clock starts with the display, not before")
        #expect(!engine.rate.isPaused)
        var host = 100.0, frames: [Int64] = [], last: TickOutcome?
        try await linkTicks(engine, clock, count: 14, host: &host) { o in
            frames.append(frame(o.time)); last = o
            #expect(o.position <= o.time)
        }
        #expect(frames.first == 10)
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a + 1 || (b == a && a == 10), "\(frames)") }
        #expect(frames.last! >= 20)
        #expect(!clock.rate.isPaused)
        let o = try #require(last)
        #expect(o.time == o.position + fd * 2, "the picture leads the clock by the display lead from the start")
    }

    @MainActor @Test func aHeadlessTickStartsAWaitingPlayAtOnce() async throws {
        let (engine, clock) = try await makeEngine()
        engine.startOnDisplayManually()
        engine.play()
        _ = engine.tick()
        #expect(!clock.rate.isPaused)
    }

    @MainActor @Test func pauseWhileThePlayStartWaitsNeverStartsTheClock() async throws {
        let (engine, clock) = try await makeEngine()
        engine.startOnDisplayManually()
        try await parked(engine, at: 10)
        engine.play()
        var host = 100.0
        try await linkTicks(engine, clock, count: 1, host: &host) { _ in }
        engine.pause()
        let at = fd * 10
        try await linkTicks(engine, clock, count: 6, host: &host) { o in #expect(o.time == at && o.position == at) }
        #expect(clock.rate.isPaused && engine.rate.isPaused && engine.position == at)
    }

    @MainActor @Test func aSeekWhileThePlayStartWaitsStartsFromTheNewPosition() async throws {
        let (engine, clock) = try await makeEngine()
        engine.startOnDisplayManually()
        try await parked(engine, at: 10)
        engine.play()
        var host = 100.0, frames: [Int64] = []
        try await linkTicks(engine, clock, count: 1, host: &host) { _ in }
        engine.seek(to: fd * 30)
        try await linkTicks(engine, clock, count: 10, host: &host) { o in frames.append(frame(o.time)) }
        #expect(frames.first == 30)
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a + 1 || (b == a && a == 30), "\(frames)") }
        #expect(!clock.rate.isPaused && frames.last! >= 35)
    }

    @MainActor @Test func theEngineLoopShowsTheFramesAfterTheWrap() async throws {
        let (engine, clock) = try await makeEngine()
        engine.startOnDisplayManually()
        engine.loops = true
        try await parked(engine, at: 50)
        engine.play()
        var host = 100.0, frames: [Int64] = [], positions: [Int64] = []
        try await linkTicks(engine, clock, count: 30, host: &host) { o in
            frames.append(frame(o.time)); positions.append(frame(o.position))
            #expect(!o.stoppedAtEdge)
        }
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == (a + 1) % 60 || (b == a && a == 50), "\(frames)") }
        #expect(frames.contains(59) && frames.contains(0) && frames.contains(1) && frames.contains(2))
        #expect(!engine.rate.isPaused && !clock.rate.isPaused)
        // The reported position (the clock) wraps too, every frame in order.
        for (a, b) in zip(positions, positions.dropFirst()) { #expect(b == (a + 1) % 60 || (b == a && a == 50), "\(positions)") }
        #expect(positions.contains(59) && positions.contains(0) && positions.contains(5))
    }

    @MainActor @Test func theEngineLoopStaysInsideThePlayRange() async throws {
        let (engine, clock) = try await makeEngine()
        engine.startOnDisplayManually()
        engine.loops = true
        engine.playRange = TimeRange(start: fd * 10, end: fd * 40)
        try await parked(engine, at: 32)
        engine.play()
        var host = 100.0, frames: [Int64] = []
        let low = fd * 10, high = fd * 39
        try await linkTicks(engine, clock, count: 30, host: &host) { o in
            frames.append(frame(o.time))
            #expect(o.time >= low && o.time <= high && o.position >= low && o.position <= high)
        }
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a + 1 || (a == 39 && b == 10) || (b == a && a == 32), "\(frames)") }
        #expect(frames.contains(39) && frames.contains(10) && frames.contains(11) && frames.contains(12))
        #expect(!engine.rate.isPaused)
    }

    @MainActor @Test func theEngineLoopWrapsInReverse() async throws {
        let (engine, clock) = try await makeEngine()
        engine.startOnDisplayManually()
        engine.loops = true
        try await parked(engine, at: 8)
        engine.play(PlaybackRate(-1, 1))
        var host = 100.0, frames: [Int64] = []
        try await linkTicks(engine, clock, count: 30, host: &host) { o in
            frames.append(frame(o.time))
            #expect(!o.stoppedAtEdge)
        }
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == (a + 59) % 60 || (b == a && a == 8), "\(frames)") }
        #expect(frames.contains(0) && frames.contains(59) && frames.contains(58))
        #expect(engine.rate.isReverse && !clock.rate.isPaused)
    }

    @MainActor @Test func pauseStaysOnTheLastFrameShown() async throws {
        let (engine, clock) = try await makeEngine()
        engine.startOnDisplayManually()
        try await parked(engine, at: 10)
        engine.play()
        var host = 100.0, shown = Time.zero, clockFrame = Time.zero
        try await linkTicks(engine, clock, count: 15, host: &host) { o in
            if o.presented { shown = o.time }
            clockFrame = o.position
        }
        #expect(shown > clockFrame, "the picture led")
        var reported: [Time] = []
        engine.onPositionChange = { reported.append($0) }
        // The last frame handed to the display is where the pause parks (picture, clock
        // and reported position). (At the moment of a pause: `DisplayLeadAudioTests`.)
        engine.pause()
        #expect(engine.position == shown && clock.now() == shown)
        #expect(reported == [shown])
        let at = shown
        try await linkTicks(engine, clock, count: 4, host: &host) { o in #expect(o.time == at && o.position == at) }
        #expect(engine.position == shown)
        // Playing on starts there.
        engine.play()
        var frames: [Int64] = []
        try await linkTicks(engine, clock, count: 8, host: &host) { o in frames.append(frame(o.time)) }
        #expect(frames.first == frame(shown))
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(b == a + 1 || (b == a && a == frame(shown)), "\(frames)") }
    }

    @Test func probeCountsAStepBackAtPause() {
        let f = 1.0 / 30
        var s: [PresentProbe.Sample] = (0..<10).map { k in
            PresentProbe.Sample(time: Double(k) * f, target: 1 + Double(k) * f, presented: 1 + Double(k) * f)
        }
        // The pause parks two frames behind the last playing frame, 100 ms later.
        s.append(PresentProbe.Sample(time: 7 * f, target: 1.4, presented: 1.4, playing: false))
        let r = PresentProbe.summarize(s, frameDuration: f)
        #expect(r.pauseStepBack == 2)
        // The paused frame takes no part in the playing figures.
        #expect(r.frames == 10 && r.intervals.count == 9 && r.late == 0 && r.skipped == 0)
        s[10].time = 9 * f
        #expect(PresentProbe.summarize(s, frameDuration: f).pauseStepBack == 0)
    }
}

@MainActor private final class WrapCount { var count = 0 }
