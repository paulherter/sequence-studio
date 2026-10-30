import Testing
import SQCore
@testable import SQPlayback

private let sr: Int64 = 48_000
private func frames(_ n: Int64) -> Time { Time(n, sr) }

@Suite struct AudioClockTests {
    @Test func holdsAtAnchorUntilTheFlushIsAcknowledgedThenRebasesExactly() {
        let audio = ManualAudio(autoFlush: false)
        let clock = AudioClock(audio: audio)
        audio.start(); audio.render(frames: 1000)               // audio that played before (old position)
        clock.start(at: Time(10, 1), rate: .forward)
        #expect(audio.lastSeek == Time(10, 1) && audio.isPlaying)
        #expect(clock.now() == Time(10, 1))
        audio.render(frames: 480)                                 // old tail still consumed: feeder has not flushed yet
        #expect(clock.now() == Time(10, 1))
        audio.applyFlush()                                        // flush issued, consumer has not applied it
        #expect(clock.now() == Time(10, 1))
        audio.render(frames: 480)                                 // consumer applies the flush at consumed = 1480
        #expect(audio.consumedAtEpoch.frames == 1480)
        #expect(clock.now() == Time(10, 1) + frames(480))
        audio.render(frames: 7)
        #expect(clock.now() == Time(10, 1) + frames(487))
    }

    @Test func subtractsFeederLatencyAndScaledOutputLatency() {
        let audio = ManualAudio(latencySamples: 480, outputLatency: frames(240))
        let clock = AudioClock(audio: audio)
        clock.start(at: Time(5, 1), rate: PlaybackRate(2))
        audio.render(frames: 900)                                 // < M + 2 x 240 = 960: nothing audible yet
        #expect(clock.now() == Time(5, 1))
        audio.render(frames: 100)                                 // 1000 - 480 - 480 = 40 timeline frames heard
        #expect(clock.now() == Time(5, 1) + frames(40))
    }

    @Test func reverseRunsBackwardsWithLatencyNeverAdded() {
        let audio = ManualAudio(latencySamples: 480, outputLatency: frames(100))
        let clock = AudioClock(audio: audio)
        clock.start(at: Time(5, 1), rate: .reverse)
        audio.render(frames: 580)
        #expect(clock.now() == Time(5, 1))
        audio.render(frames: 48_000)
        #expect(clock.now() == Time(4, 1))
        #expect(clock.rate == .reverse && audio.currentRate == .reverse)
    }

    @Test func stopHoldsAndSeekWhilePausedOnlyReanchors() {
        let audio = ManualAudio()
        let clock = AudioClock(audio: audio)
        clock.start(at: .zero, rate: .forward)
        audio.render(frames: 4800)
        #expect(clock.stop() == frames(4800))
        #expect(!audio.isPlaying && clock.rate == .zero)
        audio.render(frames: 4800)                                // not playing: nothing consumed
        #expect(clock.now() == frames(4800))
        let seeks = audio.flushed.generation
        clock.seek(to: Time(3, 1))
        #expect(clock.now() == Time(3, 1) && audio.flushed.generation == seeks)   // no restart while paused
        clock.start(at: clock.now(), rate: .forward)
        audio.render(frames: 48)
        #expect(clock.now() == Time(3, 1) + frames(48))
    }

    @Test func rateChangeAndSeekReanchorAtTheCurrentPosition() {
        let audio = ManualAudio()
        let clock = AudioClock(audio: audio)
        clock.start(at: .zero, rate: .forward)
        audio.render(frames: 48_000)
        clock.setRate(PlaybackRate(2))
        #expect(audio.lastSeek == Time(1, 1) && audio.currentRate == PlaybackRate(2))
        #expect(clock.now() == Time(1, 1))
        audio.render(frames: 96_000)                              // two timeline seconds at 2x
        #expect(clock.now() == Time(3, 1))
        clock.seek(to: Time(20, 1))
        #expect(clock.now() == Time(20, 1) && clock.rate == PlaybackRate(2))
        audio.render(frames: 480)
        #expect(clock.now() == Time(20, 1) + frames(480))
        clock.setRate(.zero)
        #expect(!audio.isPlaying && clock.now() == Time(20, 1) + frames(480))
    }

    /// 10 simulated minutes per rate: the output pulls 512-frame quanta; TimePitch consumes |rate| x 512 timeline frames
    /// per quantum (exact fractional accumulator). The clock must stay within one sequence frame of the ideal audible
    /// position `anchor + rate x (wall - outputLatency) - M` all the way through.
    @Test(arguments: [PlaybackRate(1), PlaybackRate(2), PlaybackRate(-1), PlaybackRate(1, 4)])
    func tenMinuteSimulatedDriftStaysWithinOneFrame(rate: PlaybackRate) {
        let fd = Time(1001, 30_000)
        let m = 480, outLatency = frames(512)
        let audio = ManualAudio(latencySamples: m, outputLatency: outLatency)
        let clock = AudioClock(audio: audio)
        let anchor = Time(700, 1)
        clock.start(at: anchor, rate: rate)
        let mag = rate.magnitude
        let quantum: Int64 = 512
        let quanta = 10 * 60 * sr / quantum
        var acc: Int64 = 0, wall: Int64 = 0
        var maxError = Time.zero
        for _ in 0..<quanta {
            acc += quantum * Int64(mag.num)
            let n = acc / Int64(mag.den); acc %= Int64(mag.den)
            audio.render(frames: Int(n))
            wall += quantum
            // Ideal: continuous consumption |r| x wall.
            let heard = scaled(frames(wall), by: mag) - frames(Int64(m)) - scaled(outLatency, by: mag)
            let elapsed = max(heard, .zero)
            let ideal = rate.isReverse ? anchor - elapsed : anchor + elapsed
            let err = clock.now() - ideal
            maxError = max(maxError, err.isNegative ? -err : err)
        }
        #expect(maxError <= fd, "max error \(maxError)")
        let lag = frames(Int64(m)) + scaled(outLatency, by: mag)
        let expected = anchor + scaled(Time(600, 1), by: rate) + (rate.isReverse ? lag : -lag)
        let final = clock.now() - expected
        #expect((final.isNegative ? -final : final) <= fd)
    }

    @Test func timePitchLatencyIsTakenAtEachRateChange() {
        let audio = ManualAudio(outputLatency: frames(100), timePitchLatency: frames(1000))
        let clock = AudioClock(audio: audio)
        clock.start(at: .zero, rate: .forward)
        audio.render(frames: 300)                                 // 1x: TimePitch bypassed, only 100 frames latency
        #expect(clock.now() == frames(200))
        clock.setRate(PlaybackRate(2))                            // 1100 output frames x 2 = 2200 timeline frames
        audio.render(frames: 2300)
        #expect(clock.now() == frames(300))
        clock.setRate(.forward)
        audio.render(frames: 150)
        #expect(clock.now() == frames(350))
    }

    @Test func restartHandlerReseeksAtTheCurrentPosition() {
        let audio = ManualAudio()
        let clock = AudioClock(audio: audio)
        clock.start(at: Time(2, 1), rate: .forward)
        audio.render(frames: 4800)
        let gen = audio.flushed.generation
        audio.simulateRestart()                                   // e.g. output device changed
        #expect(audio.lastSeek == Time(2, 1) + frames(4800) && clock.now() == Time(2, 1) + frames(4800))
        audio.render(frames: 480)
        #expect(audio.flushed.generation == gen + 1 && clock.now() == Time(2, 1) + frames(5280))
    }

    @Test func watchdogReportsAStallOnlyWhileRunning() {
        let audio = ManualAudio()
        let clock = AudioClock(audio: audio)
        clock.start(at: .zero, rate: .forward)
        audio.render(frames: 480)
        audio.advanceTime(nanoseconds: 200_000_000)
        #expect(!clock.sample().stalled)
        audio.render(frames: 480)                                 // progress resets the watchdog
        audio.advanceTime(nanoseconds: 200_000_000)
        #expect(!clock.sample().stalled)
        audio.advanceTime(nanoseconds: 100_000_000)
        #expect(clock.sample().stalled)
        clock.stop()
        #expect(!clock.sample().stalled)
    }

    /// 1024-frame render calls arriving with up to +-4 ms jitter; `now()` sampled every 1 ms must be monotonic, close to
    /// the ideal position (the device plays at a steady rate) and move between calls instead of in 21 ms steps.
    @Test(arguments: [PlaybackRate(1), PlaybackRate(-1), PlaybackRate(2)])
    func interpolatesBetweenJitteryRenderCalls(rate: PlaybackRate) {
        let audio = ManualAudio()
        let clock = AudioClock(audio: audio)
        let anchor = Time(10, 1)
        clock.start(at: anchor, rate: rate)
        let mag = rate.magnitude
        let q: Int64 = 1024                                       // output frames per call
        let qNanos = q * 1_000_000_000 / sr
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func jitter() -> Int64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int64(seed >> 33) % 8_000_001 - 4_000_000 }
        var nextCall = max(0, jitter()), calls: Int64 = 0, clockNanos: Int64 = 0
        func setTime(_ t: Int64) { audio.advanceTime(nanoseconds: t - clockNanos); clockNanos = t }
        var prev: Time?, increasing = 0, samples = 0, maxErr = Time.zero, maxStep = Time.zero
        for ms in 1...3000 {
            let t = Int64(ms) * 1_000_000
            while nextCall <= t {
                setTime(nextCall)
                audio.render(frames: Int(q * Int64(mag.num) / Int64(mag.den)), advance: false)
                calls += 1
                nextCall = (calls * qNanos) + jitter()
            }
            setTime(t)
            let p = clock.now()
            let ideal = anchor + scaled(Time(t, 1_000_000_000), by: rate)
            let err = p - ideal
            maxErr = max(maxErr, err.isNegative ? -err : err)
            if let prev {
                let d = rate.isReverse ? prev - p : p - prev
                #expect(!d.isNegative, "clock ran backwards at \(ms) ms")
                if d > .zero { increasing += 1 }
                maxStep = max(maxStep, d)
                samples += 1
            }
            prev = p
        }
        #expect(maxErr <= scaled(Time(10, 1000), by: mag), "max error \(maxErr)")
        #expect(Double(increasing) / Double(samples) > 0.8, "only \(increasing) of \(samples) samples moved")
        // An early call after a late one jumps by at most the jitter spread (8 ms), never by a whole 21 ms call.
        #expect(maxStep <= scaled(Time(9, 1000), by: mag), "max step \(maxStep)")
    }
}
