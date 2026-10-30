import Foundation
import Testing
@testable import SQCore

private func scene(_ count: Int, seed: UInt64) -> [Float] {
    var state = seed
    func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
    var out: [Float] = []
    while out.count < count {
        let level = Float(next() % 1000) / 1000
        for k in 0..<(Int(next() % 40) + 5) { out.append(level * (0.6 + 0.4 * Float((k * 7) % 5) / 5)) }
    }
    return Array(out.prefix(count))
}

/// The other recording: reference sampled `1 + drift` times slower, starting `lag` steps in.
private func recorded(_ ref: [Float], lag: Int, drift: Double, count: Int) -> [Float] {
    (0..<count).map { i in
        let j = Int((Double(i) * (1 + drift) + Double(lag)).rounded())
        return j >= 0 && j < ref.count ? ref[j] : 0
    }
}

@Suite struct AudioDriftFitTests {
    @Test func noDriftGivesOffsetAndNoRetime() throws {
        let ref = scene(60_000, seed: 11)
        let other = recorded(ref, lag: 1234, drift: 0, count: 50_000)
        let f = try #require(AudioDriftFit.fit(reference: ref, other: other, rate: 100))
        #expect(f.offset == Time(1234, 100))
        #expect(abs(f.driftRatio) < 1e-5)
        #expect(f.correctingSpeed == nil)
        #expect(f.chunksUsed >= 6)
    }

    @Test func driftIsFittedAndOffsetIsAtTimeZero() throws {
        let ref = scene(80_000, seed: 12)
        let other = recorded(ref, lag: 500, drift: 0.002, count: 60_000)
        let f = try #require(AudioDriftFit.fit(reference: ref, other: other, rate: 100))
        #expect(abs(f.driftRatio - 0.002) < 0.0004)
        #expect(abs(Double(f.offset.value) / Double(f.offset.timescale) - 5.0) < 0.1)
        let s = try #require(f.correctingSpeed)
        #expect(abs(Double(s.num) / Double(s.den) - 1 / 1.002) < 0.0005)
    }

    @Test func searchWindowRefusesFarOffsets() {
        let ref = scene(60_000, seed: 13)
        let other = recorded(ref, lag: 3000, drift: 0, count: 40_000)
        #expect(AudioDriftFit.fit(reference: ref, other: other, rate: 100, searchWindow: 10) == nil)
        #expect(AudioDriftFit.fit(reference: ref, other: other, rate: 100, searchWindow: 60) != nil)
    }

    @Test func shortRecordingsReportOffsetOnly() throws {
        let ref = scene(3000, seed: 14)
        let f = try #require(AudioDriftFit.fit(reference: ref, other: recorded(ref, lag: 200, drift: 0, count: 2000), rate: 100))
        #expect(f.driftRatio == 0 && f.chunkCount == 1)
    }

    @Test func timecodeModeIsADifference() {
        let f = AudioDriftFit.timecode(reference: Time(3600, 1), other: Time(3602, 1))
        #expect(f.offset == Time(2, 1) && f.method == .timecode && f.correctingSpeed == nil)
    }

    @Test func syncAudioMovesAndRetimesTheLinkedGroupInOneEdit() throws {
        let fd = Time(1, 30), link = UUID()
        var ref = Clip(name: "ref", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 3000), start: fd * 30)
        ref.mediaDuration = fd * 3000
        let other = UUID()
        var a = Clip(name: "a", media: other, kind: .audio, source: TimeRange(start: .zero, duration: fd * 1000), start: fd * 600, link: link)
        var v = Clip(name: "v", media: other, kind: .video, source: TimeRange(start: .zero, duration: fd * 1000), start: fd * 600, link: link)
        a.mediaDuration = fd * 1000; v.mediaDuration = fd * 1000
        var rt = Track(kind: .audio), at = Track(kind: .audio), vt = Track(kind: .video)
        try rt.overwrite(ref); try at.overwrite(a); try vt.overwrite(v)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [vt, rt, at])
        let fit = AudioDriftFit.Fit(offset: Time(2, 1), driftRatio: 0.01, confidence: 0.9, chunksUsed: 8, chunkCount: 8, method: .sound)
        try t.syncAudio(a.id, to: ref.id, fit: fit)
        let na = try #require(t.find(a.id)?.clip), nv = try #require(t.find(v.id)?.clip)
        #expect(na.start == fd * 30 + Time(2, 1))
        #expect(nv.start == na.start)
        #expect(abs(Double(na.speed.num) / Double(na.speed.den) - 100.0 / 101) < 1e-6)
        #expect(nv.speed == na.speed)
    }

    @Test func syncAudioWithoutRetimeKeepsSpeedAndRefusesRetimedReference() throws {
        let fd = Time(1, 30)
        var ref = Clip(name: "r", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 300), start: .zero)
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 300), start: fd * 5)
        ref.mediaDuration = fd * 300; a.mediaDuration = fd * 300
        var rt = Track(kind: .audio), at = Track(kind: .audio)
        try rt.overwrite(ref); try at.overwrite(a)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [rt, at])
        let fit = AudioDriftFit.Fit(offset: Time(1, 1), driftRatio: 0.01, confidence: 1, chunksUsed: 8, chunkCount: 8, method: .sound)
        try t.syncAudio(a.id, to: ref.id, fit: fit, retime: false)
        #expect(t.find(a.id)?.clip.speed == .normal)
        #expect(t.find(a.id)?.clip.start == fd * 30)
        try t.setSpeed(ref.id, to: ClipSpeed(num: 1, den: 2))
        #expect(throws: EditError.self) { try t.syncAudio(a.id, to: ref.id, fit: fit) }
    }

    private func rig() throws -> (Timeline, Clip, Clip) {
        let fd = Time(1, 30), link = UUID()
        var ref = Clip(name: "ref", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 3000), start: fd * 30)
        ref.mediaDuration = fd * 3000
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 100), start: fd * 600, link: link)
        a.mediaDuration = fd * 1000
        var n = Clip(name: "n", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 100), start: fd * 100)
        n.mediaDuration = fd * 100
        var rt = Track(kind: .audio), at = Track(kind: .audio)
        try rt.overwrite(ref); try at.overwrite(a); try at.overwrite(n)
        return (Timeline(name: "t", frameDuration: fd, tracks: [rt, at]), ref, a)
    }

    @Test func destinationOccupiedIsRefusedAndNothingChanges() throws {
        var (t, ref, a) = try rig()
        // Lands at frame 30 + 90 = 120: inside the neighbor at 100...200.
        let fit = AudioDriftFit.Fit(offset: Time(3, 1), driftRatio: 0, confidence: 1, chunksUsed: 1, chunkCount: 1, method: .sound)
        let before = t
        #expect(throws: EditError.self) { try t.syncAudio(a.id, to: ref.id, fit: fit) }
        #expect(t == before)
    }

    @Test func retimeGrowingIntoANeighborIsRefused() throws {
        var (t, ref, a) = try rig()
        let fd = Time(1, 30)
        var b = Clip(name: "b", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 10), start: fd * 705)
        b.mediaDuration = fd * 10
        try t.tracks[1].overwrite(b)
        // Offset keeps the clip at frame 600; speed 1/1.11 makes it 111 frames long: runs into b at 705.
        let fit = AudioDriftFit.Fit(offset: Time(19, 1), driftRatio: 0.11, confidence: 1, chunksUsed: 8, chunkCount: 8, method: .sound)
        let before = t
        #expect(throws: EditError.self) { try t.syncAudio(a.id, to: ref.id, fit: fit) }
        #expect(t == before)
    }

    @Test func refusesLinkedReferenceAndReversedTarget() throws {
        let fd = Time(1, 30), link = UUID(), media = UUID()
        var v = Clip(name: "v", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 100), start: fd * 10, link: link)
        var a = Clip(name: "a", media: media, kind: .audio, source: TimeRange(start: .zero, duration: fd * 100), start: fd * 10, link: link)
        v.mediaDuration = fd * 200; a.mediaDuration = fd * 200
        var vt = Track(kind: .video), at = Track(kind: .audio)
        try vt.overwrite(v); try at.overwrite(a)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [vt, at])
        let fit = AudioDriftFit.Fit(offset: Time(1, 1), driftRatio: 0.01, confidence: 1, chunksUsed: 8, chunkCount: 8, method: .sound)
        #expect(throws: EditError.self) { try t.syncAudio(a.id, to: v.id, fit: fit) }

        var (t2, ref, c) = try rig()
        var rev = try #require(t2.find(c.id)?.clip); rev.reversed = true
        t2.tracks[1].replace(rev)
        #expect(throws: EditError.self) { try t2.syncAudio(c.id, to: ref.id, fit: fit) }
    }

    @Test func captureDateFitIsMarkedAsTheCoarseMethod() {
        let f = AudioDriftFit.captureDate(reference: Time(100, 1), other: Time(103, 1))
        #expect(f.offset == Time(3, 1) && f.method == .captureDate && f.correctingSpeed == nil)
    }
}
