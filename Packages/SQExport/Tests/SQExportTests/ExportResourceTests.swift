import AVFoundation
import CoreVideo
import Foundation
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
import Testing
@testable import SQExport

private let fd = Time(1, 30)

/// Solid frames; media in `broken` fail to decode like a damaged file. Records `release` calls.
private actor RecordingProvider: FrameProvider {
    let solids: SolidProvider
    let broken: Set<UUID>
    private(set) var releases: [Set<UUID>] = []
    init(colors: [UUID: (b: UInt8, g: UInt8, r: UInt8)], broken: Set<UUID> = []) {
        solids = SolidProvider(colors: colors, width: 64, height: 32); self.broken = broken
    }
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        if broken.contains(media) { throw FrameDecodeError(media: media, sourceTime: sourceTime, reason: "bad slice") }
        return try await solids.frame(media: media, at: sourceTime)
    }
    func release(media: Set<UUID>) async { releases.append(media) }
}

private func clip(_ name: String, _ media: UUID, start: Time, duration: Time = Time(1, 1)) -> Clip {
    Clip(name: name, media: media, kind: .video, source: TimeRange(start: .zero, duration: duration), start: start)
}

private func timeline(_ clips: [Clip]) -> Timeline {
    Timeline(name: "t", format: SequenceFormat(width: 64, height: 32, frameDuration: fd), tracks: [Track(kind: .video, clips: clips)])
}

@Suite struct ExportMediaReleaseTests {
    /// Review #3: a media whose clips are all past is released (decoder and frames), once, and not before.
    @Test func mediaIsReleasedOnceItsLastClipIsPast() async throws {
        let a = UUID(), b = UUID()
        let p = RecordingProvider(colors: [a: (0, 0, 255), b: (0, 255, 0)])
        let tl = timeline([clip("A", a, start: .zero), clip("B", b, start: Time(1, 1)), clip("A2", a, start: Time(2, 1))])
        let src = try TimelineFrameSource(timeline: tl, provider: p, width: 64, height: 32, frameDuration: fd, frameCount: 120)
        _ = try await src.frame(at: 10)
        _ = try await src.frame(at: 40)                                   // B shows; A comes back later: kept
        #expect(await p.releases.isEmpty)
        _ = try await src.frame(at: 70)                                   // A2 shows, B is past
        #expect(await p.releases == [[b]])
        _ = try await src.frame(at: 85)
        #expect(await p.releases == [[b]])                                // never twice
        #expect(await src.releasedMedia() == [b])
    }

    /// Media inside a nested sequence live until the nested clip ends (inner times never decide).
    @Test func nestedMediaEndWithTheirNestedClip() {
        let m = UUID()
        let inner = timeline([clip("in", m, start: .zero, duration: Time(1, 2))])
        var nest = Clip(name: "nest", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: Time(1, 1))
        nest.sequence = inner.id
        let ends = TimelineFrameSource.mediaEnds(timeline([nest]), sequences: [inner.id: inner])
        #expect(ends == [m: Time(4, 1)])
    }

    /// F7.16: an Angles piece only keeps the media of the angle it shows.
    @Test func anAnglesPieceOnlyKeepsItsActiveAngle() {
        let a = UUID(), b = UUID()
        var inner = timeline([clip("a", a, start: .zero, duration: Time(3, 1))])
        inner.tracks.append(Track(kind: .video, clips: [clip("b", b, start: .zero, duration: Time(3, 1))]))
        var nest = Clip(name: "nest", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: .zero)
        nest.sequence = inner.id
        nest.angle = AngleChoice(index: 1)
        #expect(TimelineFrameSource.mediaEnds(timeline([nest]), sequences: [inner.id: inner]) == [b: Time(3, 1)])
    }
}

@Suite struct ExportDamagedFrameTests {
    /// Review #6: a decode error stops the export by default with the clip's name and the timecode.
    @Test func decodeErrorAbortsWithClipAndTime() async throws {
        let a = UUID(), bad = UUID()
        let p = RecordingProvider(colors: [a: (0, 0, 255)], broken: [bad])
        let tl = timeline([clip("Good", a, start: .zero), clip("Interview cam B", bad, start: Time(1, 1))])
        let src = try TimelineFrameSource(timeline: tl, provider: p, width: 64, height: 32, frameDuration: fd, frameCount: 60)
        _ = try await src.frame(at: 5)
        do {
            _ = try await src.frame(at: 45)
            Issue.record("expected an error")
        } catch let e as ExportDecodeError {
            #expect(e.clipName == "Interview cam B")
            #expect(e.timecode == "00:00:01:15")
            #expect(e.time == Time(45, 30))
            #expect(e.errorDescription?.contains("Interview cam B") == true)
            #expect(e.errorDescription?.contains("00:00:01:15") == true)
            #expect(e.errorDescription?.contains("bad slice") == true)
            #expect("\(e)" == e.errorDescription)          // the queue shows "\(error)"
        }
    }

    /// With "continue on damaged frames" the layer is drawn as the damaged placeholder and the export goes on.
    @Test func continueOnDamagedFramesDrawsThePlaceholder() async throws {
        let bad = UUID()
        let p = RecordingProvider(colors: [:], broken: [bad])
        let src = try TimelineFrameSource(timeline: timeline([clip("B", bad, start: .zero)]), provider: p, width: 64, height: 32,
                                          frameDuration: fd, frameCount: 30, continueOnDamagedFrames: true,
                                          renderAhead: false)     // the counter would include frame 5, rendered ahead
        _ = try await src.frame(at: 3)
        _ = try await src.frame(at: 4)
        #expect(await src.damagedLayers() == 2)
    }

    @Test func settingIsOffByDefaultAndDecodesFromOlderSettings() throws {
        var s = ExportSettings()
        #expect(!s.continueOnDamagedFrames)
        let old = try JSONEncoder().encode(s)
        #expect(!String(decoding: old, as: UTF8.self).contains("damaged"))   // older files stay byte-identical
        #expect(try JSONDecoder().decode(ExportSettings.self, from: old) == s)
        s.continueOnDamagedFrames = true
        let back = try JSONDecoder().decode(ExportSettings.self, from: try JSONEncoder().encode(s))
        #expect(back.continueOnDamagedFrames)
    }
}

@Suite(.serialized) struct DecoderBudgetTests {
    private func resolver(_ n: Int) async throws -> (StaticMediaResolver, [UUID]) {
        var spec = TestClipSpec()
        spec.width = 320; spec.height = 180; spec.frameCount = 30
        let url = try await TestClipWriter.write(spec)
        var demuxers: [UUID: any Demuxing] = [:], ids: [UUID] = []
        for _ in 0..<n { let id = UUID(); ids.append(id); demuxers[id] = try await AVDemuxer(url: url) }
        return (StaticMediaResolver(demuxers: demuxers, audio: [:]), ids)
    }

    /// Review #3: decoder sessions are capped, least recently used first, also across the providers of parallel segments.
    @Test func sessionsAreCappedLeastRecentlyUsedFirstAcrossProviders() async throws {
        let (r, m) = try await resolver(3)
        let budget = DecoderBudget(maxDecoders: 2, maxBytes: 1 << 30)
        // No look-ahead: its background store also enforces the budget, which would make the order below timing-dependent.
        let p1 = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 0)
        _ = try await p1.frame(media: m[0], at: .zero)
        _ = try await p1.frame(media: m[1], at: .zero)
        _ = try await p1.frame(media: m[0], at: Time(1, 30))              // m0 used again: m1 is the least recent
        _ = try await p1.frame(media: m[2], at: .zero)
        #expect(await p1.openMedia == [m[0], m[2]])
        #expect(budget.usage.decoders == 2)
        // A second provider (another segment) on the same budget: the first one gives way at its next decode.
        let p2 = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 0)
        _ = try await p2.frame(media: m[1], at: .zero)
        #expect(budget.usage.decoders == 3)
        _ = try await p1.frame(media: m[2], at: Time(2, 30))
        #expect(await p1.openMedia == [m[2]])
        #expect(budget.usage.decoders == 2)
        await p1.release(media: [m[2]])
        #expect(await p1.openMedia.isEmpty)
        #expect(budget.usage.decoders == 1)
        #expect(budget.usage.bytes > 0)                                   // p2's frame
    }

    /// Weak Macs: software sessions have their own cap (idle ones go, least recent first), hardware ones are not counted.
    /// Sessions in recent use are never closed for the cap (they are layers of the frames being exported).
    @Test func softwareSessionsHaveTheirOwnCap() async throws {
        let (r, m) = try await resolver(4)
        let budget = DecoderBudget(maxDecoders: 8, maxBytes: 1 << 30, maxSoftwareDecoders: 2, countsAsSoftware: { _ in true })
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 0)
        for id in m { _ = try await p.frame(media: id, at: .zero) }
        #expect(await p.openMedia.count == 4)                             // all just used: over the cap for now
        for i in 1..<30 { _ = try await p.frame(media: m[3], at: Time(Int64(i), 30)) }
        #expect(await p.openMedia.count == 2)                             // idle ones closed down to the cap
        #expect(budget.softwareSessions == 2)
        #expect(await p.openMedia.contains(m[3]))                         // the one in use stays
        await p.release(media: Set(m))
        #expect(budget.softwareSessions == 0)
        // Not counted as software (hardware): the same stack keeps all four.
        let hw = DecoderBudget(maxDecoders: 8, maxBytes: 1 << 30, maxSoftwareDecoders: 2, countsAsSoftware: { _ in false })
        let p2 = DecoderFrameProvider(resolver: r, budget: hw, lookAhead: 0)
        for id in m { _ = try await p2.frame(media: id, at: .zero) }
        #expect(await p2.openMedia.count == 4)
    }

    /// Audit: two software-only layers (picture in picture, cross dissolve) under a software cap of 1 must not close each
    /// other's session on every frame (each frame would reopen demuxer + decoder and reseek).
    @Test func softwareCapNeverThrashesLayersOfOneFrame() async throws {
        let (r, m) = try await resolver(2)
        let budget = DecoderBudget(maxDecoders: 8, maxBytes: 1 << 30, maxSoftwareDecoders: 1, countsAsSoftware: { _ in true })
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 0)
        for f in 0..<20 {
            _ = try await p.frame(media: m[0], at: Time(Int64(f), 30))
            _ = try await p.frame(media: m[1], at: Time(Int64(f), 30))
        }
        #expect(await p.opens == 2)
        #expect(await p.openMedia == Set(m))
    }

    /// Two parallel segments (one provider each) on one budget with cap 2: the excess of one segment never closes the
    /// other's layers.
    @Test func softwareCapNeverThrashesAcrossSegments() async throws {
        let (r, m) = try await resolver(4)
        let budget = DecoderBudget(maxDecoders: 8, maxBytes: 1 << 30, maxSoftwareDecoders: 2, countsAsSoftware: { _ in true })
        let p1 = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 0)
        let p2 = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 0)
        for f in 0..<20 {
            let t = Time(Int64(f), 30)
            _ = try await p1.frame(media: m[0], at: t); _ = try await p2.frame(media: m[2], at: t)
            _ = try await p1.frame(media: m[1], at: t); _ = try await p2.frame(media: m[3], at: t)
        }
        #expect(await p1.opens == 2)
        #expect(await p2.opens == 2)
    }

    /// Two layers opening at once under cap 1: the second open must not close the first one's just-opened session.
    @Test func concurrentSoftwareOpensDoNotCloseEachOther() async throws {
        let (r, m) = try await resolver(2)
        let budget = DecoderBudget(maxDecoders: 8, maxBytes: 1 << 30, maxSoftwareDecoders: 1, countsAsSoftware: { _ in true })
        let p = DecoderFrameProvider(resolver: r, budget: budget, lookAhead: 0)
        for f in 0..<10 {
            let t = Time(Int64(f), 30)
            async let a = p.frame(media: m[0], at: t)
            async let b = p.frame(media: m[1], at: t)
            _ = try await (a, b)
        }
        #expect(await p.opens == 2)
    }

    @Test func previewBudgetFollowsWorkLimits() {
        let weak = DecoderBudget.preview(MachineResources(memoryBytes: 8 << 30, cores: 8).limits)
        #expect(weak.maxSoftwareDecoders == 2 && weak.maxBytes == 192 << 20)
        let big = DecoderBudget.preview(MachineResources(memoryBytes: 32 << 30, cores: 10).limits)
        #expect(big.maxSoftwareDecoders == 8 && big.maxBytes == 768 << 20 && big.maxDecoders == 8)
    }

    /// Frame bytes are capped too: over the byte limit only the frame being returned stays.
    @Test func frameBytesAreCapped() async throws {
        let (r, m) = try await resolver(2)
        let budget = DecoderBudget(maxDecoders: 8, maxBytes: 1)
        let p = DecoderFrameProvider(resolver: r, budget: budget)
        _ = try await p.frame(media: m[0], at: .zero)
        _ = try await p.frame(media: m[1], at: .zero)
        #expect(await p.openMedia == [m[1]])
        _ = try await p.frame(media: m[1], at: Time(1, 30))
        let one = budget.usage.bytes
        _ = try await p.frame(media: m[1], at: Time(2, 30))
        #expect(budget.usage.bytes == one)                               // still one frame kept
    }
}
