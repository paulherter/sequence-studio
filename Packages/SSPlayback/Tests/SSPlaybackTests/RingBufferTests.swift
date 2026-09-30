import Testing
import Foundation
@testable import SSPlayback

@Suite struct RingBufferTests {
    private func push(_ r: RingBuffer, _ vals: [Float]) -> Int {
        vals.withUnsafeBufferPointer { p in r.push(left: p.baseAddress!, right: p.baseAddress!, count: vals.count) }
    }
    private func pop(_ r: RingBuffer, _ n: Int) -> (l: [Float], r: [Float], got: Int) {
        var l = [Float](repeating: -1, count: n), rr = [Float](repeating: -1, count: n)
        let got = l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in
            r.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: n) } }
        return (l, rr, got)
    }

    @Test func wrapsAroundPreservingOrder() {
        let r = RingBuffer(capacity: 8)
        var next: Float = 0
        for _ in 0..<10 {                       // 10 rounds of 5 frames through an 8-frame ring
            var vals: [Float] = []
            for _ in 0..<5 { vals.append(next); next += 1 }
            #expect(push(r, vals) == 5)
            let out = pop(r, 5)
            #expect(out.got == 5)
            #expect(out.l == vals && out.r == vals)
        }
        #expect(r.consumedFrames == 50)
        #expect(r.underrunCount == 0)
    }

    @Test func pushIsLimitedByFreeSpace() {
        let r = RingBuffer(capacity: 4)
        #expect(push(r, [1, 2, 3]) == 3)
        #expect(push(r, [4, 5, 6]) == 1)
        #expect(r.availableToWrite == 0)
        #expect(pop(r, 4).l == [1, 2, 3, 4])
        #expect(r.availableToWrite == 4)
    }

    @Test func underrunZeroFillsAndCounts() {
        let r = RingBuffer(capacity: 8)
        _ = push(r, [1, 2])
        let out = pop(r, 4)
        #expect(out.got == 2)
        #expect(out.l == [1, 2, 0, 0])
        #expect(r.underrunCount == 1)
        #expect(r.consumedFrames == 2)
    }

    @Test func flushDropsOldKeepsNew() {
        let r = RingBuffer(capacity: 16)
        _ = push(r, [1, 2, 3, 4])
        r.flush()
        _ = push(r, [9, 8])
        let out = pop(r, 2)
        #expect(out.l == [9, 8])
        #expect(r.consumedFrames == 2)
    }

    @Test func spscThreadsDeliverEveryFrameInOrder() async {
        let r = RingBuffer(capacity: 64)
        let total = 200_000
        let producer = Task.detached {
            var next = 0
            while next < total {
                let n = min(37, total - next)
                let vals = (0..<n).map { Float(next + $0) }
                var done = 0
                while done < n {
                    let k = vals.withUnsafeBufferPointer { p in
                        r.push(left: p.baseAddress! + done, right: p.baseAddress! + done, count: n - done) }
                    done += k
                    if k == 0 { await Task.yield() }
                }
                next += n
            }
        }
        let consumer = Task.detached { () -> Bool in
            var expect = 0
            var l = [Float](repeating: 0, count: 29), rr = [Float](repeating: 0, count: 29)
            while expect < total {
                let got = l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in
                    r.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 29) } }
                for i in 0..<got { if l[i] != Float(expect) || rr[i] != Float(expect) { return false }; expect += 1 }
                if got == 0 { await Task.yield() }
            }
            return true
        }
        await producer.value
        #expect(await consumer.value)
    }
}
