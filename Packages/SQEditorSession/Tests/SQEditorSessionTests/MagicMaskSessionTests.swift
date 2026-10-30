import Foundation
import Synchronization
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorSession

/// Magic hover after seeks (first app test): every new frame is segmented, stale requests are canceled, a frame that
/// cannot be segmented is remembered (no endless retries) and does not block the next one.
@MainActor @Suite struct MagicMaskSessionTests {
    /// One object whose column depends on the frame time (moves 2 texels per second).
    nonisolated static func frame(at s: Double) -> InstanceFrame {
        var l = [UInt8](repeating: 0, count: 20 * 10)
        let x0 = Int(s) * 2
        for y in 2..<8 { for x in x0..<(x0 + 4) where x < 20 { l[y * 20 + x] = 1 } }
        return InstanceFrame(labels: InstanceLabels(width: 20, height: 10, labels: l))
    }

    let media = UUID()
    let url = URL(fileURLWithPath: "/x.mov")

    /// Hover and a pick deinterlace the frame as the media item says (the host's closure): nil unless it is set.
    @Test func theFrameIsSegmentedWithTheMediasFieldOrder() async throws {
        let seen = Mutex<[FieldOrder?]>([])
        let frame = InstanceFrame(labels: InstanceLabels(width: 2, height: 2, labels: [1, 0, 0, 0]))
        let s = MagicMaskSession(shaped: { _, sec, _, fields in seen.withLock { $0.append(fields) }; return (frame, sec) })
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero))
        let file = url
        s.deinterlace = { $0 == file ? .bottomFirst : nil }
        #expect(await s.prepare(media: UUID(), url: url, sourceTime: .zero))
        #expect(await s.prepare(media: UUID(), url: URL(fileURLWithPath: "/progressive.mov"), sourceTime: .zero))
        #expect(seen.withLock { $0 } == [nil, .bottomFirst, nil])
    }

    /// Hover and a pick see the frame in the file's pixel shape (as Track does), and a point is a fraction of that
    /// picture with the origin at the top left.
    @Test func theFrameIsSegmentedInTheFilesPixelShapeAndPointsCountFromTheTop() async throws {
        let seen = Mutex<[PixelAspect]>([])
        // One object in the top left corner: rows 0...2, columns 0...4 of 20 x 10.
        var l = [UInt8](repeating: 0, count: 20 * 10)
        for y in 0..<3 { for x in 0..<5 { l[y * 20 + x] = 1 } }
        let frame = InstanceFrame(labels: InstanceLabels(width: 20, height: 10, labels: l))
        let s = MagicMaskSession(shaped: { _, sec, aspect, _ in seen.withLock { $0.append(aspect) }; return (frame, sec) })
        let wide = try #require(PixelAspect(2, 1)), file = url
        s.pixelAspect = { $0 == file ? wide : .square }
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero))
        #expect(await s.prepare(media: UUID(), url: URL(fileURLWithPath: "/square.mov"), sourceTime: .zero))
        #expect(seen.withLock { $0 } == [wide, .square])
        #expect(s.hover(at: Vec2(0.1, 0.1))?.label == 1)
        #expect(s.hover(at: Vec2(0.1, 0.9)) == nil && s.hover(at: Vec2(0.9, 0.1)) == nil)
        let store = MagicMatteStore(directory: nil)
        let top = [MagicPoint(position: Vec2(0.1, 0.1), subtract: false, sourceTime: .zero)]
        let bottom = [MagicPoint(position: Vec2(0.1, 0.9), subtract: false, sourceTime: .zero)]
        #expect(await s.pick(points: bottom, key: "b", store: store) == .nothing)
        #expect(await s.pick(points: top, key: "t", store: store) == .stored)
        let m = try #require(store.matte(key: "t", pts: 0))
        #expect(m.values[0] > 0.5 && m.values[m.width * (m.height - 1)] < 0.5)        // row 0 is the top
    }

    @Test func seekingBackSegmentsTheNewFrameAndHoverFollows() async throws {
        let runs = Mutex(0)
        let s = MagicMaskSession { _, sec in runs.withLock { $0 += 1 }; return (Self.frame(at: sec), sec) }
        #expect(await s.prepare(media: media, url: url, sourceTime: Time(6, 1)))
        #expect(s.hover(at: Vec2(0.65, 0.5))?.label == 1)          // object at columns 12...15
        // Back to the clip start: the old frame is not ready there, the new one is segmented and hover follows it.
        #expect(!s.isReady(media: media, sourceTime: .zero))
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero))
        #expect(s.hover(at: Vec2(0.1, 0.5))?.label == 1)            // columns 0...3
        #expect(s.hover(at: Vec2(0.65, 0.5)) == nil)
        // Asking again for the shown frame runs nothing.
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero))
        #expect(runs.withLock { $0 } == 2)
    }

    @Test func aNewerFrameCancelsTheStaleRequest() async throws {
        let cancelled = Mutex(false)
        let s = MagicMaskSession { _, sec in
            if sec > 5 {
                // Slow frame: waits until it is canceled.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
                cancelled.withLock { $0 = true }
                throw CancellationError()
            }
            return (Self.frame(at: sec), sec)
        }
        let slow = Task { await s.prepare(media: media, url: url, sourceTime: Time(9, 1)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await s.prepare(media: media, url: url, sourceTime: Time(1, 1)))
        #expect(await slow.value == false)
        #expect(cancelled.withLock { $0 })
        #expect(s.isReady(media: media, sourceTime: Time(1, 1)))
        #expect(!s.isReady(media: media, sourceTime: Time(9, 1)))
    }

    @Test func aFrameWithNothingIsRememberedAndNotRetried() async throws {
        let runs = Mutex(0)
        let s = MagicMaskSession { _, sec in runs.withLock { $0 += 1 }; return sec < 1 ? nil : (Self.frame(at: sec), sec) }
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero) == false)
        #expect(s.hasFailed(media: media, sourceTime: .zero))
        #expect(s.hover(at: Vec2(0.1, 0.5)) == nil)
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero) == false)
        #expect(runs.withLock { $0 } == 1)
        // Another frame works and clears the memo.
        #expect(await s.prepare(media: media, url: url, sourceTime: Time(2, 1)))
        #expect(!s.hasFailed(media: media, sourceTime: .zero))
        // A pick on the frame it was made on stores a matte; points of another frame do not.
        let store = MagicMatteStore(directory: nil)
        let on = [MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: Time(2, 1))]
        #expect(await s.pick(points: on, key: "k", store: store) == .stored)
        #expect(store.matte(key: "k", pts: 2) != nil)
        let other = [MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: .zero)]
        #expect(await s.pick(points: other, key: "j", store: store) == .refused)
        #expect(store.times(key: "j").isEmpty)
    }

    @Test func twoCallsForTheSameFrameShareOneRun() async throws {
        let runs = Mutex(0)
        let s = MagicMaskSession { _, sec in
            runs.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(20))
            return (Self.frame(at: sec), sec)
        }
        async let a = s.prepare(media: media, url: url, sourceTime: Time(3, 1))
        async let b = s.prepare(media: media, url: url, sourceTime: Time(3, 1))
        let (ra, rb) = await (a, b)
        #expect(ra && rb)
        #expect(runs.withLock { $0 } == 1)
    }

    // MARK: Nothing a request leaves behind switches the session off (2026-10-09)

    private struct ReadError: Error {}

    /// A request that threw is not "nothing on this frame": it says why, and it is not run on every redraw.
    @Test func aThrownErrorIsNotRememberedAsNothingThere() async throws {
        let runs = Mutex(0)
        let s = MagicMaskSession(retryDelay: 600) { _, sec in
            if runs.withLock({ $0 += 1; return $0 }) == 1 { throw NSError(domain: "sq.test", code: 7) }
            return (Self.frame(at: sec), sec)
        }
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero) == false)
        #expect(!s.hasFailed(media: media, sourceTime: .zero))
        guard case .failed(let why)? = s.problem(media: media, sourceTime: .zero) else { Issue.record("no problem kept"); return }
        #expect(why.contains("sq.test") && why.contains("7"))
        // Within the delay nothing starts by itself.
        #expect(!s.wantsPrepare(media: media, sourceTime: .zero))
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero) == false)
        #expect(runs.withLock { $0 } == 1)
        // A click (`retry`) runs it again at once.
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero, retry: true))
        #expect(s.problem(media: media, sourceTime: .zero) == nil)
    }

    /// After the delay the next hover runs a failed frame again.
    @Test func aThrownErrorIsRetriedAfterTheDelay() async {
        let runs = Mutex(0)
        let s = MagicMaskSession(retryDelay: 0) { _, sec in
            if runs.withLock({ $0 += 1; return $0 }) == 1 { throw ReadError() }
            return (Self.frame(at: sec), sec)
        }
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero) == false)
        #expect(s.wantsPrepare(media: media, sourceTime: .zero))
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero))
        #expect(runs.withLock { $0 } == 2)
    }

    /// Two callers on one request that throws both get the failure, even with no retry delay: the one that joined does
    /// not start the retry itself (the host would never tell the failure then).
    @Test func aCallerThatJoinedAFailedRequestReportsItInsteadOfRetrying() async {
        let runs = Mutex(0)
        let s = MagicMaskSession(retryDelay: 0) { _, sec in
            if runs.withLock({ $0 += 1; return $0 }) == 1 { try await Task.sleep(for: .milliseconds(20)); throw ReadError() }
            return (Self.frame(at: sec), sec)
        }
        async let first = s.prepare(media: media, url: url, sourceTime: .zero)
        async let second = s.prepare(media: media, url: url, sourceTime: .zero)
        let both = await [first, second]
        #expect(both == [false, false])
        #expect(runs.withLock { $0 } == 1)
        #expect(s.problem(media: media, sourceTime: .zero) != nil)
    }

    /// Holds a segment call (through cancellation) until the test lets it go.
    final class Gate: Sendable {
        private let state = Mutex<(open: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))
        func wait() async {
            await withCheckedContinuation { c in
                let now = state.withLock { s -> Bool in
                    if s.open { return true }
                    s.waiter = c
                    return false
                }
                if now { c.resume() }
            }
        }
        func open() {
            let w = state.withLock { s -> CheckedContinuation<Void, Never>? in
                s.open = true
                defer { s.waiter = nil }
                return s.waiter
            }
            w?.resume()
        }
    }

    /// A soft matte that never comes back (Vision hangs): the highlight and a pick still get their answer at the
    /// deadline, later highlights do not wait behind it, and a click goes on with a fresh queue.
    @Test func aSoftMatteThatHangsNeverHoldsAPickOrAHighlight() async throws {
        let hang = Mutex(true)
        let release = DispatchSemaphore(value: 0)
        let base = InstanceLabels(width: 20, height: 10, labels: (0..<200).map { $0 % 20 < 10 ? 1 : 0 })
        let frame = InstanceFrame(labels: base) { set in
            if hang.withLock({ $0 }) { release.wait() }
            return base.matte(of: set)
        }
        let s = MagicMaskSession(timeout: 0.05) { _, sec in (frame, sec) }
        #expect(await s.prepare(media: media, url: url, sourceTime: .zero))
        #expect(await s.softMatte(1) == nil)                    // given up at the deadline
        #expect(await s.softMatte(1) == nil)                    // stuck: answered at once
        let store = MagicMatteStore(directory: nil)
        let on = [MagicPoint(position: Vec2(0.25, 0.5), subtract: false, sourceTime: .zero)]
        // The pick moves on to a fresh queue; its own soft matte hangs too: it gives up, nothing is stored.
        #expect(await s.pick(points: on, key: "k", store: store) == .gaveUp(0.05))
        #expect(store.times(key: "k").isEmpty)
        // Vision answers again: the next click stores the pick.
        hang.withLock { $0 = false }
        release.signal(); release.signal()
        #expect(await s.pick(points: on, key: "k", store: store) == .stored)
        #expect(store.matte(key: "k", pts: 0) != nil)
    }

    /// A request that never comes back is given up at the deadline: the next request starts, and the late answer of the
    /// old one changes nothing.
    @Test func aRequestWithoutAnswerIsGivenUpAtTheDeadline() async throws {
        let runs = Mutex(0)
        let gate = Gate()
        let answered = Mutex(false)
        let restarts = Mutex(0)
        let s = MagicMaskSession(timeout: 0.3, retryDelay: 0, segment: { _, sec in
            if runs.withLock({ $0 += 1; return $0 }) == 1 {
                await gate.wait()                               // hangs, also when canceled
                answered.withLock { $0 = true }
            }
            return (Self.frame(at: sec), sec)
        }, onRestart: { restarts.withLock { $0 += 1 } })
        let f = Time(1, 1), g = Time(2, 1)
        #expect(await s.prepare(media: media, url: url, sourceTime: f) == false)
        #expect(s.problem(media: media, sourceTime: f) == .timedOut(0.3))
        #expect(!s.isPending(media: media, sourceTime: f))
        #expect(!s.hasFailed(media: media, sourceTime: f))
        // Hover and redraws never run a timed-out frame again (a call that hangs would be started every few seconds),
        // however long ago it was (`retryDelay` 0 here).
        #expect(!s.wantsPrepare(media: media, sourceTime: f))
        #expect(await s.prepare(media: media, url: url, sourceTime: f) == false)
        #expect(runs.withLock { $0 } == 1 && restarts.withLock { $0 } == 0)
        // A click does, on a fresh thread.
        #expect(await s.prepare(media: media, url: url, sourceTime: f, retry: true))
        #expect(runs.withLock { $0 } == 2 && restarts.withLock { $0 } == 1)
        #expect(await s.prepare(media: media, url: url, sourceTime: g))
        // The first request answers now, far too late.
        gate.open()
        for _ in 0..<400 where !answered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(answered.withLock { $0 })
        #expect(s.isReady(media: media, sourceTime: g))
        #expect(!s.isReady(media: media, sourceTime: f))
        #expect(s.hover(at: Vec2(0.25, 0.5))?.label == 1)       // G's object (columns 4...7)
        // The frame that timed out works on a click.
        #expect(await s.prepare(media: media, url: url, sourceTime: f, retry: true))
    }

    /// F, G, F again: the caller of the first F waits for the F that runs now instead of giving up.
    @Test func aSupersededCallerWaitsForTheCurrentRequestOfItsFrame() async throws {
        let runsF = Mutex(0)
        let s = MagicMaskSession { _, sec in
            if sec == 1, runsF.withLock({ $0 += 1; return $0 }) == 2 {
                try? await Task.sleep(for: .milliseconds(20))
                return (Self.frame(at: sec), sec)
            }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            throw CancellationError()
        }
        let (m, u) = (media, url)
        let first = Task { await s.prepare(media: m, url: u, sourceTime: Time(1, 1)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(s.isPending(media: media, sourceTime: Time(1, 1)))
        let other = Task { await s.prepare(media: m, url: u, sourceTime: Time(2, 1)) }
        let again = Task { await s.prepare(media: m, url: u, sourceTime: Time(1, 1)) }
        #expect(await again.value)
        #expect(await first.value)
        #expect(await other.value == false)
        #expect(runsF.withLock { $0 } == 2)
    }

    /// Hover never runs the soft matte on the main thread: it shows the hard labels, the soft matte is made beside it.
    @Test func softMattesAreMadeOffTheMainThread() async {
        let onMain = Mutex<[Bool]>([])
        let s = MagicMaskSession { _, sec in
            let hard = Self.frame(at: sec).labels
            return (InstanceFrame(labels: hard, soft: { ids in
                onMain.withLock { $0.append(Thread.isMainThread) }
                return hard.matte(of: ids)
            }), sec)
        }
        #expect(await s.prepare(media: media, url: url, sourceTime: Time(2, 1)))
        let hit = s.hover(at: Vec2(0.25, 0.5))
        #expect(hit?.label == 1 && hit?.soft == false)
        #expect(onMain.withLock { $0 }.isEmpty)
        #expect(await s.softMatte(1) != nil)
        #expect(onMain.withLock { $0 } == [false])
        #expect(s.hover(at: Vec2(0.25, 0.5))?.soft == true)
        #expect(await s.softMatte(1) != nil)
        #expect(onMain.withLock { $0 }.count == 1)
        // Another frame: its soft matte is its own.
        #expect(await s.prepare(media: media, url: url, sourceTime: Time(3, 1)))
        #expect(s.hover(at: Vec2(0.35, 0.5))?.soft == false)
    }
}
