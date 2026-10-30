import Foundation
import Testing
@testable import SQCore

@Suite struct SplitLayoutTests {
    private let fd = Time(1, 30)
    private func s(_ n: Int64) -> Time { Time(n, 1) }

    private func mediaRef(w: Int, h: Int) -> MediaRef {
        let v = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                               nominalFrameDuration: fd, isVariableFrameRate: false, rotation: 0)
        return MediaRef(name: "m", path: "/m.mov", fingerprint: MediaFingerprint(size: 1), duration: s(10),
                        info: MediaInfo(duration: s(10), video: v))
    }

    /// `n` stacked video tracks, one 10 s clip each (V1 first), all 1920x1080 pictures.
    private func project(seqW: Int, seqH: Int, n: Int) -> (Project, Timeline.ID, [Clip.ID]) {
        let m = mediaRef(w: 1920, h: 1080)
        var p = Project(name: "t", timelines: [Timeline(name: "T", format: SequenceFormat(width: seqW, height: seqH, frameDuration: fd), tracks: [])])
        p.add(m)
        var ids: [Clip.ID] = []
        var tracks: [Track] = []
        for i in 0..<n {
            let c = Clip(name: "c\(i)", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
            ids.append(c.id)
            tracks.append(Track(kind: .video, clips: [c]))
        }
        p.timelines[0].tracks = tracks
        return (p, p.timelines[0].id, ids)
    }

    private func clip(_ p: Project, _ id: Clip.ID) -> Clip { p.timelines[0].tracks.flatMap(\.clips).first { $0.id == id }! }
    private func crop(_ c: Clip, _ key: String) -> Double {
        c.effects.first { $0.kind == ClipEffect.cropKind }?.parameters[key]?.value ?? 0
    }

    // MARK: geometry

    @Test func halves16by9() {
        let cells = SplitLayout.cells(.sideBySide, canvasWidth: 1920, canvasHeight: 1080)
        #expect(cells.count == 2)
        #expect(cells[0] == SplitCell(x: 0, y: 0, width: 960, height: 1080))
        #expect(cells[1] == SplitCell(x: 960, y: 0, width: 960, height: 1080))
    }

    @Test func placementCoverFitsAndCrops() {
        // 16:9 picture into a 960x1080 cell on a 1920x1080 canvas: scale 1 (height fits), crop width 960 of 1920.
        let cell = SplitCell(x: 0, y: 0, width: 960, height: 1080)
        let p = SplitLayout.placement(of: cell, picture: (1920, 1080), canvasWidth: 1920, canvasHeight: 1080)
        #expect(p.scale == 1)
        #expect(p.position == Vec2(-480, 0))
        #expect(abs(p.crop.left - 0.25) < 1e-9 && abs(p.crop.right - 0.25) < 1e-9)
        #expect(p.crop.top == 0 && p.crop.bottom == 0)
    }

    @Test func halves9by16() {
        // Vertical canvas 1080x1920, top/bottom halves: cells 1080x960. 16:9 picture covers at scale 960/1080.
        let cells = SplitLayout.cells(.stacked, canvasWidth: 1080, canvasHeight: 1920)
        #expect(cells[0] == SplitCell(x: 0, y: 0, width: 1080, height: 960))
        let p = SplitLayout.placement(of: cells[1], picture: (1920, 1080), canvasWidth: 1080, canvasHeight: 1920)
        let sc = 960.0 / 1080.0
        #expect(abs(p.scale - sc) < 1e-9)
        #expect(p.position == Vec2(0, 480))
        let c = (1 - 1080 / (1920 * sc)) / 2
        #expect(abs(p.crop.left - c) < 1e-9 && abs(p.crop.right - c) < 1e-9)
    }

    @Test func sixtyFortyAndThree() {
        let c = SplitLayout.cells(.sixtyForty, canvasWidth: 1920, canvasHeight: 1080)
        #expect(c[0].width == 1152 && c[1].x == 1152 && c[1].width == 768)
        let t = SplitLayout.cells(.threeStacked, canvasWidth: 1080, canvasHeight: 1920)
        #expect(t.count == 3)
        #expect(t.map(\.height).reduce(0, +) == 1920)
        #expect(t[2].y == 1280)
    }

    @Test func pictureInPictureCorner() {
        let c = SplitLayout.cells(.pictureInPicture, canvasWidth: 1920, canvasHeight: 1080)
        #expect(c[0] == SplitCell(x: 0, y: 0, width: 1920, height: 1080))
        #expect(c[1].width == 576 && c[1].height == 324)
        #expect(abs(c[1].x + c[1].width - (1920 - 76.8)) < 1e-9)
    }

    @Test func pictureInPictureCircleIsSquareWithRoundedCorners() throws {
        let c = SplitLayout.cells(.pictureInPictureCircle, canvasWidth: 1920, canvasHeight: 1080)
        #expect(c[1].width == 576 && c[1].height == 576)
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 2)
        try p.applySplitLayout(.pictureInPictureCircle, to: Set(ids), in: tid)
        let top = clip(p, ids[1])
        let r = top.effects.first { $0.kind == ClipEffect.roundedCornersKind }?.parameters[ClipEffect.radiusKey]?.value
        #expect(r != nil)
        #expect(abs((r ?? 0) * top.animation.scale.value.x - 288) < 1e-6)
        #expect(clip(p, ids[0]).effects.allSatisfy { $0.kind != ClipEffect.roundedCornersKind })
    }

    @Test func gapShrinksInnerEdges() {
        let c = SplitLayout.cells(.sideBySide, canvasWidth: 1920, canvasHeight: 1080, gap: 20)
        #expect(c[0] == SplitCell(x: 0, y: 0, width: 950, height: 1080))
        #expect(c[1] == SplitCell(x: 970, y: 0, width: 950, height: 1080))
    }

    // MARK: applying

    @Test func applyWritesMotionAndCrop() throws {
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 2)
        let n = try p.applySplitLayout(.sideBySide, to: Set(ids), in: tid)
        #expect(n == 2)
        let a = clip(p, ids[0]), b = clip(p, ids[1])
        #expect(a.animation.scale.value == Vec2(1, 1))
        #expect(a.animation.position.value == Vec2(-480, 0))
        #expect(b.animation.position.value == Vec2(480, 0))
        #expect(crop(a, ClipEffect.cropLeftKey) == 25 && crop(a, ClipEffect.cropRightKey) == 25)
        #expect(!a.animation.position.isAnimated)
    }

    @Test func applyTwiceKeepsOneCropEffectAndIsEditable() throws {
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 2)
        try p.applySplitLayout(.sideBySide, to: Set(ids), in: tid)
        try p.applySplitLayout(.stacked, to: Set(ids), in: tid)
        let a = clip(p, ids[0])
        #expect(a.effects.filter { $0.kind == ClipEffect.cropKind }.count == 1)
        #expect(a.animation.position.value == Vec2(0, -270))
    }

    @Test func needsEnoughClips() {
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 2)
        #expect(throws: SplitLayoutError.self) { try p.applySplitLayout(.threeStacked, to: Set(ids), in: tid) }
        #expect(throws: SplitLayoutError.self) { try p.applySplitLayout(.sideBySide, to: [ids[0]], in: tid) }
    }

    // MARK: animation

    private func animated(_ style: SplitAnimationStyle, direction: SplitDirection = .left, ease: SplitEase = .linear,
                          inOut: (Bool, Bool) = (true, true)) throws -> (Clip, Clip) {
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 2)
        let anim = SplitAnimation(style: style, direction: direction, ease: ease, duration: s(1), animateIn: inOut.0, animateOut: inOut.1)
        try p.applySplitLayout(.sideBySide, to: Set(ids), in: tid, animation: anim)
        return (clip(p, ids[0]), clip(p, ids[1]))
    }

    @Test func slideInOutValues() throws {
        let (a, b) = try animated(.slide)
        let len = s(10)
        // Left cell enters from the left: cell right edge at canvas left edge -> x = -960 - 480.
        #expect(a.animation.position.value(atLocal: .zero) == Vec2(-1440, 0))
        #expect(a.animation.position.value(atLocal: Time(1, 2)) == Vec2(-960, 0))     // linear midpoint
        #expect(a.animation.position.value(atLocal: s(1)) == Vec2(-480, 0))
        #expect(a.animation.position.value(atLocal: s(5)) == Vec2(-480, 0))
        #expect(a.animation.position.value(atLocal: len - Time(1, 2)) == Vec2(-960, 0))
        #expect(a.animation.position.value(atLocal: len) == Vec2(-1440, 0))
        // Second cell alternates: enters from the right.
        #expect(b.animation.position.value(atLocal: .zero) == Vec2(1440, 0))
    }

    @Test func slideInOnly() throws {
        let (a, _) = try animated(.slide, inOut: (true, false))
        #expect(a.animation.position.track.keys.count == 2)
        #expect(a.animation.position.value(atLocal: s(10)) == Vec2(-480, 0))
    }

    @Test func wipeInOutValues() throws {
        let (a, _) = try animated(.wipe, direction: .left)
        func right(_ t: Time) -> Double { a.effects[0].parameters[ClipEffect.cropRightKey]!.value(atLocal: t) }
        #expect(right(.zero) == 75)                       // 100 - left(25): nothing visible
        #expect(right(Time(1, 2)) == 50)
        #expect(right(s(1)) == 25)
        #expect(right(s(10)) == 75)
        #expect(a.animation.position.value == Vec2(-480, 0))
    }

    @Test func scaleInOutValues() throws {
        let (a, _) = try animated(.scale)
        #expect(a.animation.scale.value(atLocal: .zero) == Vec2(0, 0))
        #expect(a.animation.scale.value(atLocal: Time(1, 2)) == Vec2(0.5, 0.5))
        #expect(a.animation.scale.value(atLocal: s(5)) == Vec2(1, 1))
        #expect(a.animation.scale.value(atLocal: s(10)) == Vec2(0, 0))
    }

    @Test func easeOutIsFastAtStart() throws {
        let (a, _) = try animated(.scale, ease: .easeOut)
        let mid = a.animation.scale.value(atLocal: Time(1, 2)).x
        #expect(mid > 0.5 && mid < 1)
        let (c, _) = try animated(.scale, ease: .easeIn)
        let midIn = c.animation.scale.value(atLocal: Time(1, 2)).x
        #expect(midIn < 0.5 && midIn > 0)
        #expect(c.animation.scale.value(atLocal: s(1)) == Vec2(1, 1))
    }

    @Test func durationClampedToHalfClip() throws {
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 2)
        let anim = SplitAnimation(style: .slide, duration: s(30))
        try p.applySplitLayout(.sideBySide, to: Set(ids), in: tid, animation: anim)
        let keys = clip(p, ids[0]).animation.position.track.keys.map(\.time)
        #expect(keys.first == .zero && keys.last == s(10))
        #expect(keys.allSatisfy { $0 <= s(10) })
    }

    @Test func reapplyWithoutAnimationClearsKeys() throws {
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 2)
        try p.applySplitLayout(.sideBySide, to: Set(ids), in: tid, animation: SplitAnimation(style: .slide))
        try p.applySplitLayout(.sideBySide, to: Set(ids), in: tid)
        #expect(!clip(p, ids[0]).animation.position.isAnimated)
    }

    // MARK: review fixes

    @Test func oddFrameCountsGiveStrictlyIncreasingKeys() throws {
        let f24 = Time(1, 24)
        for frames in [1, 2, 3, 5] {
            let m = mediaRef(w: 1920, h: 1080)
            var p = Project(name: "t", timelines: [Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: f24), tracks: [])])
            p.add(m)
            var tracks: [Track] = []
            var ids: [Clip.ID] = []
            for _ in 0..<2 {
                let c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: f24 * Int64(frames)), start: .zero)
                ids.append(c.id); tracks.append(Track(kind: .video, clips: [c]))
            }
            p.timelines[0].tracks = tracks
            let anim = SplitAnimation(style: .slide, ease: .linear, duration: Time(1, 2))
            try p.applySplitLayout(.sideBySide, to: Set(ids), in: p.timelines[0].id, animation: anim)
            let keys = p.timelines[0].tracks[0].clips[0].animation.position.track.keys.map(\.time)
            #expect(zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }, "frames \(frames): \(keys)")
            #expect(keys.allSatisfy { $0 <= f24 * Int64(frames) })
            if frames == 1 { #expect(keys.isEmpty) }
        }
    }

    @Test func layoutResetsRotationAndAnchor() throws {
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 2)
        var c = clip(p, ids[0])
        c.animation.rotation = AnimatedProperty(90.0)
        c.animation.anchor = AnimatedProperty(Vec2(40, 20))
        p.timelines[0].tracks[0].replace(c)
        try p.applySplitLayout(.sideBySide, to: Set(ids), in: tid)
        let a = clip(p, ids[0])
        #expect(a.animation.rotation.value == 0 && !a.animation.rotation.isAnimated)
        #expect(a.animation.anchor.value == .zero)
    }

    @Test func clipsOnTheSameTrackAreRefused() {
        var (p, tid, ids) = project(seqW: 1920, seqH: 1080, n: 1)
        let m = p.media.first!
        let second = Clip(name: "d", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: s(10))
        try! p.timelines[0].tracks[0].overwrite(second)
        let all = Set(p.timelines[0].tracks[0].clips.map(\.id))
        #expect(all.count == 2 && ids.count == 1)
        #expect(throws: SplitLayoutError.sameTrack) { try p.applySplitLayout(.sideBySide, to: all, in: tid) }
    }
}
