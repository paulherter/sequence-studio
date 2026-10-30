import Foundation
import SQCore
import Testing
@testable import SQAppShell

@MainActor
struct HoverFeederTests {
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        private var points: [Vec2] = []
        var running = 0, overlap = false
        func add(_ p: Vec2) { lock.lock(); points.append(p); lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return running }
        func begin() { lock.lock(); running += 1; if running > 1 { overlap = true }; lock.unlock() }
        func end() { lock.lock(); running -= 1; lock.unlock() }
        var all: [Vec2] { lock.lock(); defer { lock.unlock() }; return points }
    }

    private func settle(_ f: HoverFeeder<Int>) async {
        for _ in 0..<400 where f.isPending { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aBurstOfMovesAsksOnceForTheLastPoint() async {
        let log = Log()
        let f = HoverFeeder<Int>(delay: .milliseconds(20)) { p, _ in log.add(p); return 7 }
        var changes = 0
        f.onChange = { changes += 1 }
        for i in 0..<10 { f.move(Vec2(Double(i) / 10, 0.5), seconds: 1) }
        await settle(f)
        #expect(log.all == [Vec2(0.9, 0.5)])
        #expect(f.answer?.value == 7 && f.answer?.seconds == 1 && changes == 1)
    }

    @Test func clearDropsTheAnswerAndAnInFlightOne() async {
        let f = HoverFeeder<Int>(delay: .milliseconds(5)) { _, _ in try? await Task.sleep(for: .milliseconds(60)); return 1 }
        var changes = 0
        f.onChange = { changes += 1 }
        f.move(Vec2(0.5, 0.5), seconds: 0)
        try? await Task.sleep(for: .milliseconds(30))
        f.clear()
        await settle(f)
        #expect(f.answer == nil && changes == 0, "the answer of a cleared hover never shows")
        f.move(Vec2(0.5, 0.5), seconds: 0)
        await settle(f)
        #expect(f.answer != nil && changes == 1)
        f.clear()
        #expect(f.answer == nil && changes == 2)
    }

    @Test func oneAnswerRunsAtATimeAndALateResultIsStillShown() async {
        let log = Log()
        let f = HoverFeeder<Int>(delay: .milliseconds(5)) { p, _ in
            log.begin()
            try? await Task.sleep(for: .milliseconds(40))
            log.end()
            log.add(p)
            return 3
        }
        f.move(Vec2(0.1, 0.1), seconds: 0)
        for _ in 0..<400 where log.current == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        f.move(Vec2(0.2, 0.2), seconds: 0)        // arrives while the first runs
        await settle(f)
        #expect(!log.overlap)
        #expect(log.all == [Vec2(0.1, 0.1), Vec2(0.2, 0.2)])
        #expect(f.answer?.value == 3)
    }

    @Test func noObjectThereHidesTheOldHighlight() async {
        let f = HoverFeeder<Int>(delay: .milliseconds(5)) { p, _ in p.x < 0.5 ? 1 : nil }
        f.move(Vec2(0.2, 0.2), seconds: 0)
        await settle(f)
        #expect(f.answer != nil)
        f.move(Vec2(0.9, 0.2), seconds: 0)
        await settle(f)
        #expect(f.answer == nil)
    }
}
