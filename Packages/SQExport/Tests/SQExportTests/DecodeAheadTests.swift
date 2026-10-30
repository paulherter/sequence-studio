import CoreVideo
import Foundation
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
import Testing
import VideoToolbox
@testable import SQExport

// Export speed (PLAYBACK-PERF "Export speed"): while the export composites and encodes frame N, the provider already
// decodes the next frames of a media that moves forward, so the render rarely waits on the decoder.

private func stamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

@Suite(.serialized) struct DecodeAheadTests {
    private func resolver() async throws -> (StaticMediaResolver, UUID) {
        var spec = TestClipSpec(); spec.frameCount = 60
        let id = UUID()
        return (StaticMediaResolver(demuxers: [id: try await AVDemuxer(url: try await TestClipWriter.write(spec))], audio: [:]), id)
    }

    @Test func forwardFramesAreDecodedAheadAndExact() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4)
        var got: [Int?] = []
        for i in 0..<40 { got.append(try await p.frame(media: m, at: Time(Int64(i), 30)).map { stamp($0.buffer) } ?? nil) }
        #expect(got == (0..<40).map { Optional($0) })
        // Most frames come from the look-ahead, not from a decode on the request path.
        let n = await p.requestDecodes
        #expect(n <= 40 / 4 + 2, "request decodes \(n)")
    }

    /// The look-ahead refills in runs (one decoder call for several frames: a 4K long-GOP frame costs ~9 ms decoded
    /// alone and ~5-6 ms in a run of 4-8, PLAYBACK-PERF "Export: look-ahead decodes in runs"), not one call per frame.
    @Test func lookAheadRefillsInRuns() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r)
        var got: [Int?] = []
        for i in 0..<48 {
            got.append(try await p.frame(media: m, at: Time(Int64(i), 30)).map { stamp($0.buffer) } ?? nil)
            // The export spends compose + encode time per frame, so the look-ahead is done before the next request.
            // Without this a loaded machine requests frames before the background run ends (flaky request count).
            await p.settle()
        }
        #expect(got == (0..<48).map { Optional($0) })
        let calls = await p.aheadDecodeCalls, requests = await p.requestDecodes
        #expect(calls <= 48 / 4 + 2, "look-ahead decoder calls \(calls)")
        #expect(requests <= 2, "request decodes \(requests)")
    }

    @Test func noLookAheadDecodesEveryFrameOnRequest() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 0)
        for i in 0..<10 { _ = try await p.frame(media: m, at: Time(Int64(i), 30)) }
        #expect(await p.requestDecodes == 10)
    }

    /// Speed 2x (every other source frame), a jump back and repeated frames stay exact.
    @Test func skipsJumpsAndRepeatsStayExact() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4)
        let want = [0, 2, 4, 6, 8, 10, 10, 11, 3, 4, 5, 50, 51, 52, 59, 59]
        var got: [Int?] = []
        for i in want { got.append(try await p.frame(media: m, at: Time(Int64(i), 30)).map { stamp($0.buffer) } ?? nil) }
        #expect(got == want.map { Optional($0) })
    }

    /// Frames decoded ahead never push the shared byte budget over its limit.
    @Test func lookAheadKeepsTheByteBudget() async throws {
        let (r, m) = try await resolver()
        let budget = DecoderBudget(maxDecoders: 8, maxBytes: 1)
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 4)
        _ = try await p.frame(media: m, at: .zero)
        let one = budget.usage.bytes
        for i in 1..<12 { _ = try await p.frame(media: m, at: Time(Int64(i), 30)) }
        await p.settle()
        #expect(budget.usage.bytes == one)
    }

    /// Releasing a media cancels its look-ahead; its session stays counted until the canceled decode has ended.
    @Test func releaseCancelsTheLookAheadAndFreesTheSession() async throws {
        let (r, m) = try await resolver()
        let budget = DecoderBudget()
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 8)
        _ = try await p.frame(media: m, at: .zero)
        _ = try await p.frame(media: m, at: Time(1, 30))
        await p.release(media: [m])
        #expect(budget.usage.decoders <= 1)
        await p.settle()
        #expect(budget.usage == (0, 0))
        #expect(await p.openMedia.isEmpty)
        // Opens again, exact.
        let f = try await p.frame(media: m, at: Time(20, 30))
        #expect(f.map { stamp($0.buffer) } == 20)
    }

    /// A canceled request does not wait for the whole look-ahead and leaves the provider usable and exact.
    @Test func cancelledRequestEndsAndLaterRequestsStayExact() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 8)
        _ = try await p.frame(media: m, at: .zero)
        _ = try await p.frame(media: m, at: Time(1, 30))
        let t = Task { try await p.frame(media: m, at: Time(40, 30)) }
        t.cancel()
        _ = try? await t.value
        var got: [Int?] = []
        for i in 41..<50 { got.append(try await p.frame(media: m, at: Time(Int64(i), 30)).map { stamp($0.buffer) } ?? nil) }
        #expect(got == (41..<50).map { Optional($0) })
    }

    /// At a step of 3 the look-ahead decodes only the frames it keeps, not every frame of the span.
    @Test func lookAheadReturnsOnlyWantedFrames() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4)
        var got: [Int?] = []
        for i in stride(from: 0, to: 57, by: 3) {
            got.append(try await p.frame(media: m, at: Time(Int64(i), 30)).map { stamp($0.buffer) } ?? nil)
        }
        await p.settle()
        #expect(got == stride(from: 0, to: 57, by: 3).map { Optional($0) })
        let unwanted = await p.aheadUnwanted
        #expect(unwanted == 0)
    }

    /// Frames just requested stay kept after the look-ahead stores its frames: going back one frame is not a new decode.
    @Test func recentlyRequestedFramesSurviveTheLookAhead() async throws {
        let (r, m) = try await resolver()
        let p = DecoderFrameProvider(resolver: r, lookAhead: 4)
        for i in 0...10 { _ = try await p.frame(media: m, at: Time(Int64(i), 30)) }
        await p.settle()
        let before = await p.requestDecodes
        let f9 = try await p.frame(media: m, at: Time(9, 30))
        let f10 = try await p.frame(media: m, at: Time(10, 30))
        #expect(f9.map { stamp($0.buffer) } == 9 && f10.map { stamp($0.buffer) } == 10)
        let after = await p.requestDecodes
        #expect(after == before)
    }

    /// Byte reservations are atomic across threads: exactly as many succeed as fit.
    @Test func budgetReservationIsAtomic() async {
        let budget = DecoderBudget(maxDecoders: 8, maxBytes: 10)
        let ok = await withTaskGroup(of: Bool.self) { g in
            for _ in 0..<200 { g.addTask { budget.reserve(bytes: 1) } }
            var n = 0
            for await r in g where r { n += 1 }
            return n
        }
        #expect(ok == 10)
        #expect(budget.usage.bytes == 10)
    }
}
