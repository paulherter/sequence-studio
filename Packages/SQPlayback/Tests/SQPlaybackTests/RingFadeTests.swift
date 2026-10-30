import Testing
import Foundation
@testable import SQPlayback

@Suite struct RingFadeTests {
    private let F = 240
    private func push(_ r: RingBuffer, _ v: Float, _ n: Int) {
        let a = [Float](repeating: v, count: n)
        _ = a.withUnsafeBufferPointer { p in r.push(left: p.baseAddress!, right: p.baseAddress!, count: n) }
    }
    private func pop(_ r: RingBuffer, _ n: Int) -> [Float] {
        var l = [Float](repeating: -1, count: n), rr = l
        l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in
            _ = r.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
        return l
    }
    private func gIn(_ k: Int) -> Float { Float(0.5 - 0.5 * cos(Double.pi * (Double(k) + 0.5) / Double(F))) }

    @Test func flushReturnsEpochAndConsumerPublishesConsumedAtApply() {
        let r = RingBuffer(capacity: 2048)
        #expect(r.consumedAtEpoch.epoch == 0)
        push(r, 1, 500)
        _ = pop(r, 100)
        let e = r.flush()
        #expect(e == 1)
        #expect(r.consumedAtEpoch.epoch == 0)            // consumer has not run yet
        push(r, 1, 200)
        _ = pop(r, 50)
        #expect(r.consumedAtEpoch.epoch == e)
        #expect(r.consumedAtEpoch.frames == 100)         // consumedFrames at the moment the flush was applied
        #expect(r.consumedFrames == 150)
        #expect(r.flush() == 2)
    }

    @Test func coalescedFlushesPublishLatestEpoch() {
        let r = RingBuffer(capacity: 2048)
        push(r, 1, 300); _ = pop(r, 10)
        r.flush(); let e2 = r.flush()
        push(r, 1, 100); _ = pop(r, 10)
        #expect(r.consumedAtEpoch.epoch == e2 && r.consumedAtEpoch.frames == 10)
    }

    @Test func freshStartFadesInOverFiveMs() {
        let r = RingBuffer(capacity: 4096, fadeFrames: F)
        push(r, 1, 100); r.flush()                        // seek: nothing was playing
        push(r, 1, 1000)
        let o = pop(r, 1000)
        for k in 0..<F { #expect(abs(o[k] - gIn(k)) < 1e-6, "k=\(k)") }
        #expect(zip(o[0..<F], o[1..<F]).allSatisfy { $1 > $0 })
        #expect(o[0] < 0.001 && o[F - 1] > 0.999)
        #expect(o[F...].allSatisfy { $0 == 1 })
    }

    @Test func flushDuringPlaybackCrossfadesOldTailOut() {
        let r = RingBuffer(capacity: 4096, fadeFrames: F)
        push(r, 1, 1000)
        _ = pop(r, 100)                                   // playing; 900 old frames still queued
        r.flush()
        push(r, 0, 1000)                                  // new material is silent: output = fade-out envelope of the old tail
        let o = pop(r, 400)
        for k in 0..<F { #expect(abs(o[k] - (1 - gIn(k))) < 1e-6, "k=\(k)") }
        #expect(zip(o[0..<F], o[1..<F]).allSatisfy { $1 < $0 })
        #expect(o[F...].allSatisfy { $0 == 0 })
        #expect(r.consumedFrames == 500)                  // the old tail is not counted: clock re-bases exactly
    }

    @Test func sameSignalAcrossFlushStaysAtUnity() {
        let r = RingBuffer(capacity: 4096, fadeFrames: F)
        push(r, 1, 1000); _ = pop(r, 100)
        r.flush(); push(r, 1, 1000)
        #expect(pop(r, 300).allSatisfy { abs($0 - 1) < 1e-6 })   // fade-out + fade-in of equal signals sum to 1
    }

    @Test func staleTailIsNotPlayedAfterLongPause() async throws {
        let r = RingBuffer(capacity: 4096, fadeFrames: F, staleAfter: 0.01)
        push(r, 1, 1000); _ = pop(r, 100)
        try await Task.sleep(for: .milliseconds(60))      // consumer paused
        r.flush(); push(r, 0, 1000)
        #expect(pop(r, 300).allSatisfy { $0 == 0 })       // no 5 ms blip of the old material
    }

    @Test func fadeInAdvancesOnlyWithRealData() {
        let r = RingBuffer(capacity: 4096, fadeFrames: F)
        r.flush()
        let first = pop(r, 100)                           // underrun: silence, ramp must not be consumed
        #expect(first.allSatisfy { $0 == 0 })
        push(r, 1, 500)
        let o = pop(r, 300)
        #expect(abs(o[0] - gIn(0)) < 1e-6)
    }

    @Test func partialFirstPopKeepsCrossfadeAtUnity() {
        let r = RingBuffer(capacity: 4096, fadeFrames: F)
        push(r, 1, 1000); _ = pop(r, 100)
        r.flush(); push(r, 1, 100)
        var l = [Float](repeating: -1, count: 300), rr = l
        let n = l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in
            r.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 300) } }
        #expect(n == 100)
        #expect(l[0..<100].allSatisfy { abs($0 - 1) < 1e-6 })
        push(r, 1, 500)
        #expect(pop(r, 200).allSatisfy { abs($0 - 1) < 1e-6 })
    }
}
