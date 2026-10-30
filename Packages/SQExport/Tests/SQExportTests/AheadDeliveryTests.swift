import CoreVideo
import Foundation
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
import Testing
import VideoToolbox
@testable import SQExport

// Export look-ahead (PLAYBACK-PERF "Export: look-ahead frames taken as they arrive"): a frame of a look-ahead run is
// kept when the decoder hands it out, so the frame loop takes it before the run's decoder call has returned.

private func stamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

/// Holds decoder calls until it is opened (a watchdog opens it after 20 s, so a failing test ends instead of hanging).
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false, waiting: [CheckedContinuation<Void, Never>] = []
    private var passedCalls = 0, arrivedCalls = 0, late = false
    private var watchdog: Task<Void, Never>?

    init() {
        watchdog = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(20))) != nil else { return }
            self?.open(timedOut: true)
        }
    }
    deinit { watchdog?.cancel() }

    func pass() async {
        lock.withLock { arrivedCalls += 1 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiting.append(c)
                return false
            }
            if go { c.resume() }
        }
        lock.withLock { passedCalls += 1 }
    }

    func open(timedOut: Bool = false) {
        let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            if !isOpen, timedOut { late = true }
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        for c in w { c.resume() }
    }

    /// Gated calls that have gone through.
    var passed: Int { lock.withLock { passedCalls } }
    /// Gated calls that have reached the gate (passed or waiting).
    var arrived: Int { lock.withLock { arrivedCalls } }
    var timedOut: Bool { lock.withLock { late } }
}

/// The real decoder; calls of more than one frame (look-ahead runs) wait at the gate before decoding (`before`) or
/// after every frame is decoded and handed out, before the call returns.
private final class GatedDecoder: VideoDecoding, @unchecked Sendable {
    let inner: any VideoDecoding, gate: Gate, before: Bool
    init(_ inner: any VideoDecoding, gate: Gate, before: Bool) { self.inner = inner; self.gate = gate; self.before = before }
    var info: VideoTrackInfo { inner.info }
    var isHardware: Bool { inner.isHardware }
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] { try await inner.decode(range) }
    func decode(_ range: ClosedRange<Int>, deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        try await decode(range, neededFrom: nil, deliver: deliver)
    }
    func decode(_ range: ClosedRange<Int>, neededFrom: Int?,
                deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        guard range.count > 1 else { return try await inner.decode(range, neededFrom: neededFrom, deliver: deliver) }
        if before { await gate.pass() }
        let rest = try await inner.decode(range, neededFrom: neededFrom, deliver: deliver)
        if !before { await gate.pass() }
        return rest
    }
    func invalidate() { inner.invalidate() }
}

@Suite(.serialized) struct AheadDeliveryTests {
    private func resolver() async throws -> (StaticMediaResolver, UUID) {
        var spec = TestClipSpec(); spec.frameCount = 60
        let id = UUID()
        return (StaticMediaResolver(demuxers: [id: try await AVDemuxer(url: try await TestClipWriter.write(spec))], audio: [:]), id)
    }

    private func gated(_ r: StaticMediaResolver, budget: DecoderBudget = DecoderBudget(), before: Bool,
                       deliversEarly: Bool = true) async -> (DecoderFrameProvider, Gate) {
        let gate = Gate()
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 8, deliversEarly: deliversEarly)
        await p.setDecoderWrap { GatedDecoder($0, gate: gate, before: before) }
        return (p, gate)
    }

    /// Bytes of one decoded frame of the clip.
    private func frameBytes(_ r: StaticMediaResolver, _ m: UUID) async throws -> Int {
        let budget = DecoderBudget()
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 0)
        _ = try await p.frame(media: m, at: .zero)
        let one = budget.usage.bytes
        #expect(one > 0)
        await p.release(media: [m])
        return one
    }

    private func frame(_ p: DecoderFrameProvider, _ m: UUID, _ i: Int) async throws -> Int? {
        try await p.frame(media: m, at: Time(Int64(i), 30)).map { stamp($0.buffer) } ?? nil
    }

    /// The frames of a run are handed to requests while the run's decoder call has not returned.
    @Test func framesAreTakenBeforeTheirRunEnds() async throws {
        let (r, m) = try await resolver()
        let (p, gate) = await gated(r, before: false)
        #expect(try await frame(p, m, 0) == 0)
        // The look-ahead now decodes a run from frame 1; its call cannot return (gate closed).
        var got: [Int?] = []
        for i in 1...4 { got.append(try await frame(p, m, i)) }
        #expect(got == [1, 2, 3, 4])
        #expect(gate.passed == 0, "the run's call had not returned when its frames were taken")
        #expect(!gate.timedOut)
        gate.open()
        await p.settle()
        got = []
        for i in 5..<24 { got.append(try await frame(p, m, i)) }
        #expect(got == (5..<24).map { Optional($0) })
        #expect(await p.aheadUnwanted == 0)
    }

    /// The next frame missing with no look-ahead running (the frame loop caught up with the decoder) starts a run at
    /// that frame instead of a decode of it alone.
    @Test func caughtUpRequestStartsARun() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 8)
        var got: [Int?] = []
        for i in 0..<40 { got.append(try await frame(p, m, i)) }
        #expect(got == (0..<40).map { Optional($0) })
        // One decode alone (frame 0: nothing known about the direction yet); every other frame comes from a run.
        #expect(await p.requestDecodes == 1)
        #expect(await p.aheadUnwanted == 0)
    }

    /// A run that ends starts the next one while the window has room for it: the decoder does not wait for a request.
    @Test func nextRunStartsWhenARunEnds() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 8)
        #expect(try await frame(p, m, 0) == 0)
        await p.settle()
        // Two runs of 4 fill the window of 8; nothing is decoded beyond it.
        #expect(await p.kept(m).frames == Array(0...8))
        #expect(await p.aheadDecodeCalls == 2)
    }

    /// With the default window (12 in runs of 6) and frames so large that the per-media byte limit holds fewer, the
    /// look-ahead stops where the limit does: no frame it decoded is trimmed before use, no run seeks back.
    @Test func windowStopsAtTheByteLimit() async throws {
        let (r, m) = try await resolver()
        let one = try await frameBytes(r, m)
        // Room for the last request and 7 ahead.
        let p = DecoderFrameProvider(resolver: r, lookAhead: 12, recentByteLimit: one * 8 + one / 2)
        for i in 0..<50 {
            #expect(try await frame(p, m, i) == i)
            if i % 4 == 0 { await p.settle() }
            let k = await p.kept(m)
            #expect(k.frames.filter { $0 > i }.count <= 7, "ahead of \(i): \(k.frames)")
        }
        #expect(await p.aheadReseeks == 0)
        #expect(await p.requestDecodes == 1)
        #expect(await p.aheadUnwanted == 0)
    }

    /// A request elsewhere while a run is in flight waits for that run only: no further run is chained at the old
    /// position. A loop back afterwards is exact.
    @Test func jumpDuringARunChainsNothing() async throws {
        let (r, m) = try await resolver()
        let (p, gate) = await gated(r, before: true)
        #expect(try await frame(p, m, 0) == 0)
        while gate.arrived == 0, !gate.timedOut { await Task.yield() }
        let t = Task { try await p.frame(media: m, at: Time(40, 30)) }
        while await p.waiting(m) == 0, !gate.timedOut { await Task.yield() }
        gate.open()
        #expect(try await t.value.map { stamp($0.buffer) } == 40)
        #expect(await p.aheadDecodeCalls == 1, "only the run in flight when the jump came")
        #expect(!gate.timedOut)
        var got: [Int?] = []
        for i in 0..<6 { got.append(try await frame(p, m, i)) }
        #expect(got == (0..<6).map { Optional($0) })
        await p.settle()
        #expect(await p.aheadPending == (0, 0))
    }

    /// A request waiting for a run while its media is closed and reopened starts over on the new session: it leaves no
    /// waiting count and no busy mark behind, so the reopened lane keeps chaining runs, and frames stay exact.
    @Test func requestOutlivingItsSessionStartsOver() async throws {
        let (r, m) = try await resolver()
        let (p, gate) = await gated(r, before: true)
        #expect(try await frame(p, m, 0) == 0)
        while gate.arrived == 0, !gate.timedOut { await Task.yield() }
        let t = Task { try await p.frame(media: m, at: Time(40, 30)) }
        while await p.waiting(m) == 0, !gate.timedOut { await Task.yield() }
        await p.invalidate(media: m)
        let reopened = Task { try await p.frame(media: m, at: Time(0, 30)) }
        while await p.sessionCount == 0, !gate.timedOut { await Task.yield() }
        gate.open()
        #expect(try await t.value.map { stamp($0.buffer) } == 40)
        #expect(try await reopened.value.map { stamp($0.buffer) } == 0)
        #expect(!gate.timedOut)
        #expect(await p.requestRestarts == 1)
        await p.settle()
        #expect(await p.waiting(m) == 0)
        let calls = await p.aheadDecodeCalls
        var got: [Int?] = []
        for i in 41..<60 { got.append(try await frame(p, m, i)) }
        #expect(got == (41..<60).map { Optional($0) })
        #expect(await p.aheadDecodeCalls > calls, "the reopened lane still runs ahead")
        await p.settle()
        #expect(await p.aheadPending == (0, 0))
    }

    /// `deliversEarly: false` (`SQ_EXPORT_AHEAD_DELIVER=0`): a run's frames are kept only when its call returns, and
    /// frames stay exact.
    @Test func oldDeliveryKeepsFramesAtCallEnd() async throws {
        let (r, m) = try await resolver()
        let (p, gate) = await gated(r, before: false, deliversEarly: false)
        #expect(try await frame(p, m, 0) == 0)
        while gate.arrived == 0, !gate.timedOut { await Task.yield() }
        let t = Task { try await p.frame(media: m, at: Time(1, 30)) }
        while await p.waiting(m) == 0, !gate.timedOut { await Task.yield() }
        #expect(await p.kept(m).frames == [0], "nothing kept before the call returns")
        gate.open()
        #expect(try await t.value.map { stamp($0.buffer) } == 1)
        #expect(gate.passed >= 1)
        var got: [Int?] = []
        for i in 2..<30 { got.append(try await frame(p, m, i)) }
        #expect(got == (2..<30).map { Optional($0) })
        #expect(await p.aheadShortened == 0)
        #expect(await p.aheadUnwanted == 0)
    }

    /// Frames held ahead of the last request never exceed the window, whether the frame loop keeps up or stands still.
    @Test func framesHeldAheadStayWithinTheWindow() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 8)
        for i in 0..<40 {
            #expect(try await frame(p, m, i) == i)
            // Standing still: everything the look-ahead decodes for this position has arrived.
            if i % 3 == 0 { await p.settle() }
            let k = await p.kept(m)
            #expect(k.frames.filter { $0 > i }.count <= 8, "ahead of \(i): \(k.frames)")
            #expect(k.frames.count <= 8 + 4, "kept at \(i): \(k.frames)")
            #expect(k.frames.allSatisfy { $0 <= i + 8 }, "kept at \(i): \(k.frames)")
        }
    }

    /// A run that does not fit the byte budget is cut to what fits; the budget is never exceeded and frames stay exact.
    @Test func runIsCutToTheByteBudget() async throws {
        let (r, m) = try await resolver()
        let one = try await frameBytes(r, m)
        let budget = DecoderBudget(maxDecoders: 8, maxBytes: one * 3 + one / 2)
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 8)
        for i in 0..<30 {
            #expect(try await frame(p, m, i) == i)
            #expect(budget.usage.bytes <= budget.maxBytes, "at \(i)")
            if i % 2 == 0 { await p.settle() }
            #expect(budget.usage.bytes <= budget.maxBytes, "settled at \(i)")
        }
        #expect(await p.aheadShortened > 0)
        await p.settle()
        #expect(await p.aheadPending == (0, 0))
    }

    /// A request canceled while it waits for a frame of the running look-ahead ends with it: no waiter, no reserved
    /// bytes and no uncounted frame stay behind, and later requests are exact.
    @Test func cancelWhileWaitingForARunLeavesNothingBehind() async throws {
        let (r, m) = try await resolver()
        let budget = DecoderBudget()
        let (p, gate) = await gated(r, budget: budget, before: true)
        let one = try await frameBytes(r, m)
        #expect(try await frame(p, m, 0) == 0)
        // Frame 1 is a target of the run held at the gate: the request waits for it.
        let t = Task { try await p.frame(media: m, at: Time(1, 30)) }
        while await p.aheadPending.waiters == 0, !gate.timedOut { await Task.yield() }
        #expect(await p.aheadPending.reserved == 4 * one)
        t.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { _ = try await t.value }
        #expect(!gate.timedOut)
        await p.settle()
        #expect(await p.aheadPending == (0, 0))
        #expect(budget.usage.bytes == (await p.kept(m)).frames.count * one)
        var got: [Int?] = []
        for i in 1..<12 { got.append(try await frame(p, m, i)) }
        #expect(got == (1..<12).map { Optional($0) })
        await p.settle()
        #expect(await p.aheadPending == (0, 0))
        #expect(budget.usage.bytes == (await p.kept(m)).frames.count * one)
    }

    /// A request for a frame elsewhere, canceled while a run is still open, cancels the run; the frames it had handed
    /// out stay counted exactly.
    @Test func cancelDuringARunKeepsTheCount() async throws {
        let (r, m) = try await resolver()
        let budget = DecoderBudget()
        let (p, gate) = await gated(r, budget: budget, before: false)
        let one = try await frameBytes(r, m)
        #expect(try await frame(p, m, 0) == 0)
        #expect(try await frame(p, m, 1) == 1)
        // The run's call has handed out its frames and holds at the gate; the request for 40 waits for it.
        while gate.arrived == 0, !gate.timedOut { await Task.yield() }
        let t = Task { try await p.frame(media: m, at: Time(40, 30)) }
        while await p.waiting(m) == 0, !gate.timedOut { await Task.yield() }
        t.cancel()
        gate.open()
        _ = try? await t.value
        #expect(!gate.timedOut)
        await p.settle()
        #expect(await p.aheadPending == (0, 0))
        #expect(budget.usage.bytes == (await p.kept(m)).frames.count * one)
        var got: [Int?] = []
        for i in 41..<50 { got.append(try await frame(p, m, i)) }
        #expect(got == (41..<50).map { Optional($0) })
    }

    /// A media released while its run is decoding keeps none of the frames the run hands out afterwards.
    @Test func releaseDuringARunKeepsNoFrame() async throws {
        let (r, m) = try await resolver()
        let budget = DecoderBudget()
        let (p, gate) = await gated(r, budget: budget, before: true)
        #expect(try await frame(p, m, 0) == 0)
        // The run from frame 1 waits at the gate; the release ends once the canceled run has.
        while gate.arrived == 0, !gate.timedOut { await Task.yield() }
        async let released: Void = p.release(media: [m])
        while await p.drainingCount == 0, !gate.timedOut { await Task.yield() }
        gate.open()
        await released
        await p.settle()
        #expect(!gate.timedOut)
        #expect(budget.usage == (0, 0))
        #expect(await p.kept(m).frames.isEmpty)
        #expect(await p.aheadPending == (0, 0))
        #expect(try await frame(p, m, 20) == 20)
    }
}
