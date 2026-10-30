import Foundation
import Testing
@testable import SQCore

@Suite struct FrameScaleTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private let fd = Time(1, 30)

    private func mediaRef(w: Int, h: Int, rotation: Int = 0) -> MediaRef {
        let v = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, rotation: rotation)
        return MediaRef(name: "m", path: "/m.mov", fingerprint: MediaFingerprint(size: 1), duration: s(10),
                        info: MediaInfo(duration: s(10), video: v))
    }

    private func project(seqW: Int, seqH: Int, media: MediaRef, scale: Vec2 = Vec2(1, 1)) -> (Project, Timeline.ID, Clip.ID) {
        var p = Project(name: "t", timelines: [Timeline(name: "T", format: SequenceFormat(frameDuration: fd), tracks: [Track(kind: .video)])])
        p.add(media)
        var clip = Clip(name: "c", media: media.id, kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        clip.animation.scale = AnimatedProperty(scale)
        p.timelines[0].format = SequenceFormat(width: seqW, height: seqH, frameDuration: fd)
        p.timelines[0].tracks = [Track(kind: .video, clips: [clip])]
        return (p, p.timelines[0].id, clip.id)
    }

    @Test func fitScaleExamples() {
        let f1080 = SequenceFormat(width: 1080, height: 1920, frameDuration: fd)
        #expect(SequenceFormat(width: 1920, height: 1080, frameDuration: fd).fitScale(width: 3840, height: 2160) == 0.5)
        // 4K phone clip rotated 90 degrees: upright 2160 x 3840 fills a 1080 x 1920 sequence at 50 %, not 28 %.
        #expect(f1080.fitScale(width: 2160, height: 3840) == 0.5)
        #expect(abs(f1080.fitScale(width: 3840, height: 2160) - 0.28125) < 1e-12)
        #expect(f1080.fitScale(width: 0, height: 10) == 1)
    }

    @Test func pictureSizeUsesRotationAndNesting() throws {
        let m = mediaRef(w: 3840, h: 2160, rotation: 90)
        var (p, tl, _) = project(seqW: 1080, seqH: 1920, media: m)
        let clip = p.timelines[0].tracks[0].clips[0]
        #expect(p.pictureSize(of: clip)! == (2160, 3840))
        let inner = Timeline(name: "in", format: SequenceFormat(width: 1280, height: 720, frameDuration: fd), tracks: [Track(kind: .video)])
        p.timelines.append(inner)
        let nested = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: .zero, sequence: inner.id)
        #expect(p.pictureSize(of: nested)! == (1280, 720))
        let gen = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: .zero,
                       generator: GeneratorRef(kind: "text", payload: Data()))
        #expect(p.pictureSize(of: gen) == nil)
        _ = tl
    }

    @Test func setToFrameSizeWritesFitAndDropsScaleKeys() throws {
        let m = mediaRef(w: 3840, h: 2160, rotation: 90)
        var (p, tl, id) = project(seqW: 1080, seqH: 1920, media: m, scale: Vec2(2, 2))
        var c = p.timelines[0].tracks[0].clips[0]
        c.animation.scale.track.insert(Keyframe(time: .zero, value: Vec2(3, 3)))
        p.timelines[0].tracks[0].replace(c)
        #expect(try p.setToFrameSize([id], in: tl) == 1)
        let n = p.timelines[0].tracks[0].clips[0]
        #expect(n.animation.scale.value == Vec2(0.5, 0.5) && !n.animation.scale.isAnimated)
        #expect(try p.setToFrameSize([id], in: tl) == 0)                      // already there
        #expect(throws: EditError.timelineNotFound) { try p.setToFrameSize([id], in: UUID()) }
    }

    @Test func setToFrameSizeRefusesLockedTrackAndSkipsGenerators() throws {
        let m = mediaRef(w: 3840, h: 2160)
        var (p, tl, id) = project(seqW: 1920, seqH: 1080, media: m)
        p.timelines[0].tracks[0].isLocked = true
        #expect(throws: EditError.trackLocked) { try p.setToFrameSize([id], in: tl) }
        #expect(p.timelines[0].tracks[0].clips[0].animation.scale.value == Vec2(1, 1))
    }

    @Test func migrationKeepsOnScreenSize() throws {
        let m = mediaRef(w: 3840, h: 2160)
        var (p, _, _) = project(seqW: 1920, seqH: 1080, media: m, scale: Vec2(2, 1.5))
        var c = p.timelines[0].tracks[0].clips[0]
        c.animation.scale.track.insert(Keyframe(time: s(1), value: Vec2(4, 4)))
        p.timelines[0].tracks[0].replace(c)
        let gen = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: s(6),
                       generator: GeneratorRef(kind: "text", payload: Data()))
        try p.timelines[0].tracks[0].overwrite(gen)
        p.migrateScaleToSourcePixels()
        let clips = p.timelines[0].tracks[0].clips
        let media = try #require(clips.first { !$0.isGenerator })
        #expect(media.animation.scale.value == Vec2(1, 0.75))                 // fit 0.5
        #expect(media.animation.scale.track.keys[0].value == Vec2(2, 2))
        #expect(clips.first { $0.isGenerator }?.animation.scale.value == Vec2(1, 1))
    }

    @Test func migrationSkipsUnknownSizesAndAudio() throws {
        var (p, _, _) = project(seqW: 1920, seqH: 1080, media: mediaRef(w: 3840, h: 2160))
        p.media[0].info = nil
        p.migrateScaleToSourcePixels()
        #expect(p.timelines[0].tracks[0].clips[0].animation.scale.value == Vec2(1, 1))
    }

    @Test func loadingAV9FileMigratesOnceAndV10KeepsValues() throws {
        let m = mediaRef(w: 3840, h: 2160)
        let (p, _, _) = project(seqW: 1920, seqH: 1080, media: m, scale: Vec2(1, 1))
        // Write as v9 by hand: same JSON, older version number.
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 9
        let v9 = try JSONSerialization.data(withJSONObject: obj)
        let loaded = try ProjectFile.decode(v9, migrations: ProjectFile.migrations)
        #expect(loaded.timelines[0].tracks[0].clips[0].animation.scale.value == Vec2(0.5, 0.5))
        // Saved again (now v10), loading leaves it alone.
        let again = try ProjectFile.decode(ProjectFile.encode(loaded), migrations: ProjectFile.migrations)
        #expect(again.timelines[0].tracks[0].clips[0].animation.scale.value == Vec2(0.5, 0.5))
    }

    @Test func placementWithInitialScaleOnVideoOnly() throws {
        var t = Timeline(name: "t", format: SequenceFormat(frameDuration: fd), tracks: [Track(kind: .video), Track(kind: .audio)])
        try t.threePointEdit(source: TimeRange(start: .zero, duration: s(2)), media: UUID(), mediaDuration: s(2), initialScale: 0.5,
                             targets: t.tracks.map(\.id), at: .zero, mode: .overwrite)
        #expect(t.tracks[0].clips[0].animation.scale.value == Vec2(0.5, 0.5))
        #expect(t.tracks[1].clips[0].animation.scale.value == Vec2(1, 1))
    }

    @Test func migrationKeepsCornersWithAnchorAndKeyframes() throws {
        let m = mediaRef(w: 3840, h: 2160)
        var (p, _, _) = project(seqW: 1920, seqH: 1080, media: m, scale: Vec2(1.2, 0.9))
        var c = p.timelines[0].tracks[0].clips[0]
        c.animation.anchor = AnimatedProperty(Vec2(100, -40))
        c.animation.anchor.track.insert(Keyframe(time: s(1), value: Vec2(300, 80)))
        c.animation.position = AnimatedProperty(Vec2(25, 10))
        c.animation.rotation = AnimatedProperty(30.0)
        p.timelines[0].tracks[0].replace(c)
        let tl = p.timelines[0]
        let before = tl.tracks[0].clips[0]
        // Layer corner on screen: position + rotate(scale * (corner - anchor)); corner in layer px (old: fitted, new: native).
        func corners(_ clip: Clip, size: (Double, Double), at t: Time) -> [Vec2] {
            let tr = clip.transform(at: t)
            let a = tr.rotation * .pi / 180
            return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { sx, sy in
                let lx = (sx * size.0 / 2 - tr.anchor.x) * tr.scale.x, ly = (sy * size.1 / 2 - tr.anchor.y) * tr.scale.y
                return Vec2(tr.position.x + lx * cos(a) - ly * sin(a), tr.position.y + lx * sin(a) + ly * cos(a))
            }
        }
        let times = [Time.zero, Time(1, 2), s(1), s(2)]
        let old = times.map { corners(before, size: (1920, 1080), at: $0) }
        p.migrateScaleToSourcePixels()
        let after = p.timelines[0].tracks[0].clips[0]
        for (i, t) in times.enumerated() {
            let now = corners(after, size: (3840, 2160), at: t)
            for (a, b) in zip(old[i], now) { #expect(abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6) }
        }
    }

    @Test func fillScaleCoversFrame() {
        let f = SequenceFormat(width: 1080, height: 1920, frameDuration: fd)
        #expect(abs(f.fillScale(width: 1920, height: 1080) - 1920.0 / 1080.0) < 1e-12)
        #expect(abs(f.fitScale(width: 1920, height: 1080) - 0.5625) < 1e-12)
        #expect(f.fillScale(width: 2160, height: 3840) == 0.5)          // rotated phone clip: fit == fill
        #expect(f.fillScale(width: 0, height: 5) == 1)
    }

    @Test func setToFillFrameWritesFillDropsKeysAndSkipsGenerators() throws {
        var (p, tl, id) = project(seqW: 1080, seqH: 1920, media: mediaRef(w: 1920, h: 1080))
        var c = p.timelines[0].tracks[0].clips[0]
        c.animation.scale.track.insert(Keyframe(time: s(1), value: Vec2(2, 2)))
        p.timelines[0].tracks[0].replace(c)
        #expect(try p.setToFillFrame([id], in: tl) == 1)
        let n = p.timelines[0].tracks[0].clips[0]
        #expect(abs(n.animation.scale.value.x - 1920.0 / 1080.0) < 1e-12)
        #expect(n.animation.scale.track.keys.isEmpty)
        #expect(try p.setToFillFrame([id], in: tl) == 0)
        #expect(throws: EditError.timelineNotFound) { try p.setToFillFrame([id], in: UUID()) }
        // nest clip uses the inner sequence size
        let inner = Timeline(name: "in", format: SequenceFormat(width: 1280, height: 720, frameDuration: fd), tracks: [Track(kind: .video)])
        p.timelines.append(inner)
        let nest = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: .zero, sequence: inner.id)
        p.timelines[0].tracks[0] = Track(kind: .video, clips: p.timelines[0].tracks[0].clips + [nest])
        #expect(try p.setToFillFrame([nest.id], in: tl) == 1)
        let ns = p.timelines[0].tracks[0].clips.first { $0.id == nest.id }!
        #expect(abs(ns.animation.scale.value.x - 1920.0 / 720.0) < 1e-12)
        var gen = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: .zero,
                       generator: GeneratorRef(kind: "text", payload: Data()))
        gen.start = s(20)
        p.timelines[0].tracks[0] = Track(kind: .video, clips: p.timelines[0].tracks[0].clips + [gen])
        #expect(try p.setToFillFrame([gen.id], in: tl) == 0)
    }
}
