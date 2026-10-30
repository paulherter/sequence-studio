import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

/// The Magic matte look-ahead prepares the source frames the next ticks show, whatever maps timeline time to source.
@Suite struct MatteLookAheadTests {
    static let fd = Time(1, 30)

    /// 30 fps source of `frames` frames.
    static func index(frames: Int) -> SampleIndex {
        SampleIndex(entries: (0..<frames).map {
            SampleIndex.Entry(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 % 15 == 0, decodeOrdinal: $0)
        })
    }

    /// The source frame numbers prepared at timeline frame `at` of a 30 fps sequence holding one 20 s clip, and the
    /// frame shown there.
    static func ahead(at: Int64, rate: PlaybackRate = .forward, speed: ClipSpeed = .normal, reversed: Bool = false,
                      start: Time = .zero) -> (shown: Int, coming: [Int]) {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(20, 1)),
                        start: start, speed: speed, reversed: reversed)
        let track = Track(kind: .video, clips: [clip])
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [track])
        let idx = index(frames: 600)
        let t = fd * at
        let shown = tl.videoLayers(at: t).first.map { RenderLoop.frameIndex($0.sourceTime, in: idx) } ?? -1
        let times = MatteLookAhead.sourceTimes(after: t, frame: fd, rate: rate, count: 4, clips: [clip.id]) { tl.videoLayers(at: $0) }
        let coming = MatteLookAhead.frames(times[clip.id] ?? [], shown: shown, in: idx)
        return (shown, coming.map { Int(($0 * 30).rounded()) })
    }

    @Test func aPlainClipPreparesTheNextFourFrames() {
        let a = Self.ahead(at: 10)
        #expect(a.shown == 10 && a.coming == [11, 12, 13, 14])
    }

    @Test func aReversedClipPreparesTheFramesBeforeTheShownOne() {
        let a = Self.ahead(at: 10, reversed: true)
        #expect(a.shown > 500)
        #expect(a.coming == (1...4).map { a.shown - $0 })
    }

    @Test func aFastClipPreparesEverySecondOrSixthFrame() {
        let two = Self.ahead(at: 10, speed: ClipSpeed(num: 2, den: 1))
        #expect(two.shown == 20 && two.coming == [22, 24, 26, 28])
        let six = Self.ahead(at: 10, speed: ClipSpeed(num: 6, den: 1))
        #expect(six.shown == 60 && six.coming == [66, 72, 78, 84])
        let reversedSix = Self.ahead(at: 10, speed: ClipSpeed(num: 6, den: 1), reversed: true)
        #expect(reversedSix.coming == (1...4).map { reversedSix.shown - 6 * $0 })
    }

    @Test func aSlowClipPreparesEachFrameOnce() {
        // Half speed: two ticks per source frame, so four ticks ahead are two frames.
        let a = Self.ahead(at: 10, speed: ClipSpeed(num: 1, den: 2))
        #expect(a.shown == 5 && a.coming == [6, 7])
    }

    @Test func reversePlaybackOfAForwardClipPreparesTheFramesBefore() {
        let a = Self.ahead(at: 10, rate: .reverse)
        #expect(a.shown == 10 && a.coming == [9, 8, 7, 6])
        // ... and of a reversed clip the frames after.
        let b = Self.ahead(at: 10, rate: .reverse, reversed: true)
        #expect(b.coming == (1...4).map { b.shown + $0 })
        // Near the sequence start nothing before it is asked for.
        #expect(Self.ahead(at: 2, rate: .reverse).coming == [1, 0])
    }

    @Test func fastAndSlowPlaybackStepWithTheClock() {
        #expect(Self.ahead(at: 10, rate: PlaybackRate(2)).coming == [12, 14, 16, 18])
        #expect(Self.ahead(at: 20, rate: PlaybackRate(-4)).coming == [16, 12, 8, 4])
        // Half rate: every frame is shown two ticks long, the next four different frames are prepared.
        #expect(Self.ahead(at: 10, rate: PlaybackRate(1, 2)).coming == [11, 12, 13, 14])
        #expect(MatteLookAhead.times(after: Self.fd * 10, frame: Self.fd, rate: .zero, count: 4).isEmpty)
    }

    /// A dense sequence: `tracks` video tracks of 12-frame clips over `frames` frames, the first two tracks made of
    /// nested clips of an inner sequence built the same way (reversed and fast clips in it). `masks`: every clip of
    /// one track of each sequence has a Magic mask, so three masked layers show at a time (one of them twice, through
    /// both nested clips).
    static func dense(tracks: Int, frames: Int64, masks: Bool = true) -> (top: Timeline, inner: Timeline) {
        func masked(_ c: Clip) -> Clip {
            var c = c
            c.masks = [ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false,
                                                                               sourceTime: c.source.start)])]
            return c
        }
        func row(_ n: Int, nested inner: Timeline?) -> Track {
            var clips: [Clip] = []
            var at: Int64 = Int64(n % 5)
            var k = 0
            while at + 12 <= frames {
                let fast = k % 4 == 1
                let source = TimeRange(start: Time(1, 1), duration: fd * (fast ? 24 : 12))
                var c: Clip
                if let inner {
                    c = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: fd * at, duration: fd * 12),
                             start: fd * at, sequence: inner.id)
                } else {
                    c = Clip(name: "c", media: UUID(), kind: .video, source: source, start: fd * at,
                             speed: fast ? ClipSpeed(num: 2, den: 1) : .normal, reversed: k % 4 == 2)
                    if masks, n == 5 { c = masked(c) }
                }
                clips.append(c)
                at += 12
                k += 1
            }
            return Track(kind: .video, clips: clips)
        }
        let inner = Timeline(name: "inner", frameDuration: fd, tracks: (0..<tracks).map { row($0, nested: nil) })
        let top = Timeline(name: "top", frameDuration: fd,
                           tracks: (0..<tracks).map { row($0 + 1, nested: $0 < 2 ? inner : nil) })
        return (top, inner)
    }

    /// The look-ahead of a tick inside its clips evaluates the timeline no second time, and gives exactly the source
    /// times four more evaluations give. The cost of both ways on a dense sequence with nested ones is printed.
    @Test func theLookAheadOfADenseNestedSequenceCostsNoFourEvaluations() {
        let (top, inner) = Self.dense(tracks: 8, frames: 6000)
        let sequences: SequenceResolver = { $0 == inner.id ? inner : nil }
        func layers(_ t: Time) -> [LayerRequest] { top.videoLayers(at: t, sequences: sequences) }
        let ticks: [Int64] = Array(600..<900)
        let now = ticks.map { layers(Self.fd * $0) }
        var maskedLayers = 0
        for rate in [PlaybackRate.forward, .reverse] {
            var evaluations = 0
            for (n, f) in ticks.enumerated() {
                let t = Self.fd * f
                let masked = Set(now[n].filter { r in r.effects.magicMattes.contains { !$0.mustCover } }.map(\.clip))
                maskedLayers += masked.count
                let full = MatteLookAhead.sourceTimes(after: t, frame: Self.fd, rate: rate, count: 4, clips: masked, layers: layers)
                let derived = MatteLookAhead.sourceTimes(after: t, frame: Self.fd, rate: rate, count: 4, requests: now[n], in: top,
                                                         sequences: sequences) { evaluations += 1; return layers($0) }
                #expect(derived == full, "frame \(f)")
            }
            // 12-frame clips, the nested ones staggered: an edge is within four frames on half of the ticks, and only
            // the times behind it are evaluated.
            #expect(evaluations < ticks.count * 2, "\(evaluations) evaluations in \(ticks.count) ticks")
        }
        #expect(maskedLayers >= ticks.count * 4)

        func micros(_ body: () -> Void) -> Double {
            let d = ContinuousClock().measure(body)
            return (Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12) / Double(ticks.count)
        }
        var one = Double.infinity, before = one, after = one, calmBefore = one, calmAfter = one
        let measureOne = { for f in ticks { _ = layers(Self.fd * f) } }
        let measureBefore = {
            for (n, f) in ticks.enumerated() {
                let masked = Set(now[n].filter { r in r.effects.magicMattes.contains { !$0.mustCover } }.map(\.clip))
                _ = MatteLookAhead.sourceTimes(after: Self.fd * f, frame: Self.fd, rate: .forward, count: 4, clips: masked, layers: layers)
            }
        }
        let measureAfter = {
            for (n, f) in ticks.enumerated() {
                _ = MatteLookAhead.sourceTimes(after: Self.fd * f, frame: Self.fd, rate: .forward, count: 4, requests: now[n], in: top,
                                               sequences: sequences, layers: layers)
            }
        }
        // A long clip (no edge within four frames on any tick): the common case of a masked interview shot.
        let (calmTop, calmInner) = Self.dense(tracks: 8, frames: 6000, masks: false)
        var long = Clip(name: "long", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Self.fd * 6000), start: .zero)
        long.masks = [ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])]
        var calm = calmTop
        calm.tracks.append(Track(kind: .video, clips: [long]))
        let calmSequences: SequenceResolver = { $0 == calmInner.id ? calmInner : nil }
        func calmLayers(_ t: Time) -> [LayerRequest] { calm.videoLayers(at: t, sequences: calmSequences) }
        let calmNow = ticks.map { calmLayers(Self.fd * $0) }
        var calmEvaluations = 0
        let measureCalmBefore = {
            for (n, f) in ticks.enumerated() {
                _ = MatteLookAhead.sourceTimes(after: Self.fd * f, frame: Self.fd, rate: .forward, count: 4, clips: [long.id]) {
                    _ = n; return calmLayers($0)
                }
            }
        }
        let measureCalmAfter = {
            for (n, f) in ticks.enumerated() {
                _ = MatteLookAhead.sourceTimes(after: Self.fd * f, frame: Self.fd, rate: .forward, count: 4, requests: calmNow[n],
                                               in: calm, sequences: calmSequences) { calmEvaluations += 1; return calmLayers($0) }
            }
        }
        // Best of five rounds, the ways taking turns: other work on the machine hits them alike.
        for _ in 0..<5 {
            one = min(one, micros(measureOne))
            before = min(before, micros(measureBefore)); after = min(after, micros(measureAfter))
            calmBefore = min(calmBefore, micros(measureCalmBefore)); calmAfter = min(calmAfter, micros(measureCalmAfter))
        }
        #expect(calmEvaluations == 0)
        func s(_ v: Double) -> String { String(format: "%.1f", v) }
        print("PERF matte look-ahead per tick, 8 tracks + 2 nested: evaluation \(s(one)) us | three 12-frame masked clips: before "
            + "\(s(before)) us, after \(s(after)) us | one long masked clip: before \(s(calmBefore)) us, after \(s(calmAfter)) us")
        #expect(after < before, "look-ahead \(after) us per tick, four evaluations \(before) us")
        #expect(calmAfter < calmBefore / 4, "one long clip: \(calmAfter) us per tick, four evaluations \(calmBefore) us")
    }

    /// A masked clip whose Crop takes the whole picture away is no layer of the tick (`Timeline.videoLayers` leaves
    /// it out, at the top and inside a sequence), so the look-ahead prepares none of its mattes and the render
    /// thread never asks the store for one. The same clip with part of its picture left is prepared as before.
    @Test func aFullyCroppedMaskedClipPreparesNothing() {
        func masked(crop: Double) -> Clip {
            var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(20, 1)), start: .zero)
            c.masks = [ClipMask.makeMagic(name: "Mask (1)", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero)])]
            c.effects = [ClipEffect(kind: ClipEffect.cropKind, parameters: [ClipEffect.cropLeftKey: AnimatedProperty(crop)])]
            return c
        }
        func ahead(_ clip: Clip, nested: Bool) -> (layers: Int, times: [Clip.ID: [Time]], evaluations: Int) {
            let inner = Timeline(name: "inner", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [clip])])
            var top = inner
            if nested {
                let n = Clip(name: "n", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(20, 1)), start: .zero,
                             sequence: inner.id)
                top = Timeline(name: "top", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [n])])
            }
            let sequences: SequenceResolver = { $0 == inner.id ? inner : nil }
            let t = Self.fd * 10
            let requests = top.videoLayers(at: t, sequences: sequences)
            var evaluations = 0
            let times = MatteLookAhead.sourceTimes(after: t, frame: Self.fd, rate: .forward, count: 4, requests: requests,
                                                   in: top, sequences: sequences) { evaluations += 1; return top.videoLayers(at: $0, sequences: sequences) }
            return (requests.count, times, evaluations)
        }
        for nested in [false, true] {
            let gone = ahead(masked(crop: 100), nested: nested)
            #expect(gone.layers == 0 && gone.times.isEmpty && gone.evaluations == 0, "nested \(nested)")
            let part = masked(crop: 60)
            let shown = ahead(part, nested: nested)
            #expect(shown.layers == 1 && shown.times[part.id]?.count == 4, "nested \(nested)")
        }
        // What a tick spends on a fully cropped masked clip in the look-ahead: nothing but the empty check.
        let clip = masked(crop: 100)
        let tl = Timeline(name: "t", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [clip])])
        let start = DispatchTime.now().uptimeNanoseconds
        for f in 0..<300 {
            let t = Self.fd * Int64(f)
            _ = MatteLookAhead.sourceTimes(after: t, frame: Self.fd, rate: .forward, count: 4, requests: tl.videoLayers(at: t),
                                           in: tl, sequences: { _ in nil }) { tl.videoLayers(at: $0) }
        }
        let us = Double(DispatchTime.now().uptimeNanoseconds - start) / 300 / 1000
        print("PERF matte look-ahead per tick, one fully cropped masked clip (evaluation included): \(String(format: "%.1f", us)) us")
    }

    @Test func nothingIsPreparedPastTheClipsEnd() {
        // A 20 s clip ends at timeline frame 600: at 598 only one more frame of it is shown.
        #expect(Self.ahead(at: 598).coming == [599])
        // A clip that starts later is not asked before it is on.
        #expect(Self.ahead(at: 10, start: Time(1, 1)).coming.isEmpty)
    }
}
