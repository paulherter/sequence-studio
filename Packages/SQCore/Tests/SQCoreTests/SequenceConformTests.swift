import Foundation
import Testing
@testable import SQCore

@Suite struct SequenceConformTests {
    private let fd = Time(1, 30)
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private func fmt(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: fd) }
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    private func close(_ a: Vec2, _ b: Vec2) -> Bool { close(a.x, b.x) && close(a.y, b.y) }

    private func videoClip(start: Int64 = 0, scale: Vec2 = Vec2(1, 1), position: Vec2 = .zero) -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: s(start))
        c.animation.scale = AnimatedProperty(scale)
        c.animation.position = AnimatedProperty(position)
        return c
    }

    private func textClip(position: Vec2 = .zero, scale: Vec2 = Vec2(1, 1)) -> Clip {
        var c = videoClip(start: 10, scale: scale, position: position)
        let g = GeneratorRef(kind: GeneratorRef.text, payload: Data("t".utf8))
        c.generator = g
        c.media = c.id
        c.name = "Title"
        return c
    }

    private func project(_ clips: [Clip], audio: [Clip] = [], format: SequenceFormat? = nil) -> (Project, Timeline.ID) {
        let t = Timeline(name: "Main", format: format ?? fmt(1920, 1080),
                         tracks: [Track(kind: .video, clips: clips), Track(kind: .audio, clips: audio)])
        return (Project(name: "p", timelines: [t]), t.id)
    }

    // MARK: Pure maths

    @Test func frameFactorFitAndFill() {
        let hd = fmt(1920, 1080), vert = fmt(1080, 1920), classic = fmt(1440, 1080), square = fmt(1080, 1080)
        #expect(close(SequenceConform.frameFactor(from: hd, to: vert, mode: .fill), 1920.0 / 1080.0))
        #expect(close(SequenceConform.frameFactor(from: hd, to: vert, mode: .fit), 1080.0 / 1920.0))
        #expect(close(SequenceConform.frameFactor(from: hd, to: classic, mode: .fill), 1))
        #expect(close(SequenceConform.frameFactor(from: hd, to: classic, mode: .fit), 0.75))
        #expect(close(SequenceConform.frameFactor(from: hd, to: square, mode: .fill), 1))
        #expect(close(SequenceConform.frameFactor(from: hd, to: hd, mode: .fit), 1))
        // Same aspect, bigger frame: both modes scale up equally.
        #expect(close(SequenceConform.frameFactor(from: hd, to: fmt(3840, 2160), mode: .fit), 2))
        #expect(close(SequenceConform.frameFactor(from: hd, to: fmt(3840, 2160), mode: .fill), 2))
    }

    @Test func safeAreaIsTitleSafe() {
        let a = SequenceConform.safeHalfExtent(of: fmt(1080, 1920))
        #expect(close(a.x, 1080 * 0.4))
        #expect(close(a.y, 1920 * 0.4))
    }

    @Test func aspectPresetsCoverFiveShapes() {
        let names = SequenceConform.aspectPresets.map(\.name)
        #expect(names == ["9:16", "16:9", "4:5", "1:1", "4:3"])
        let p = SequenceConform.aspectPresets[0]
        #expect(p.width == 1080 && p.height == 1920)
    }

    // MARK: Picture clips

    @Test func fillScalesValuePositionAndKeys() throws {
        var c = videoClip(scale: Vec2(1, 1), position: Vec2(90, -60))
        c.animation.position.track = KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(0, 0), outTangent: Vec2(30, 0)),
            Keyframe(time: s(1), value: Vec2(300, 150), inTangent: Vec2(-30, 6)),
        ])
        c.animation.scale.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(1, 1)), Keyframe(time: s(2), value: Vec2(2, 2))])
        c.animation.anchor = AnimatedProperty(Vec2(10, 20))
        c.animation.rotation = AnimatedProperty(15)
        var (p, id) = project([c])
        try p.changeFormat(of: id, to: fmt(1080, 1920), mode: .fill)
        let t = try #require(p.timeline(id))
        #expect(t.format.width == 1080 && t.format.height == 1920 && t.format.frameDuration == fd)
        let n = try #require(t.tracks[0].clips.first)
        let k = 1920.0 / 1080.0
        #expect(close(n.animation.scale.value, Vec2(k, k)))
        #expect(close(n.animation.position.value, Vec2(90 * k, -60 * k)))
        #expect(close(n.animation.position.track.keys[1].value, Vec2(300 * k, 150 * k)))
        #expect(close(n.animation.position.track.keys[0].outTangent, Vec2(30 * k, 0)))
        #expect(close(n.animation.position.track.keys[1].inTangent, Vec2(-30 * k, 6 * k)))
        #expect(close(n.animation.scale.track.keys[1].value, Vec2(2 * k, 2 * k)))
        #expect(n.animation.position.track.keys[1].time == s(1))
        // Anchor is layer-local and rotation is frame-independent: untouched.
        #expect(n.animation.anchor == c.animation.anchor)
        #expect(n.animation.rotation == c.animation.rotation)
        #expect(n.id == c.id && n.start == c.start && n.source == c.source)
    }

    @Test func fitLetterboxesAndPerClipOverride() throws {
        let a = videoClip(start: 0), b = videoClip(start: 5)
        var (p, id) = project([a, b])
        try p.changeFormat(of: id, to: fmt(1080, 1920), mode: .fit, overrides: [b.id: .fill])
        let clips = try #require(p.timeline(id)).tracks[0].clips
        #expect(close(clips[0].animation.scale.value.x, 1080.0 / 1920.0))
        #expect(close(clips[1].animation.scale.value.x, 1920.0 / 1080.0))
    }

    @Test func audioClipsAndSolidsUntouched() throws {
        var solid = videoClip(start: 20)
        solid.generator = .solid(rgb: [0, 0, 0])
        solid.media = solid.id
        let audio = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
        var (p, id) = project([solid], audio: [audio])
        try p.changeFormat(of: id, to: fmt(1080, 1350), mode: .fill)
        let t = try #require(p.timeline(id))
        #expect(t.tracks[0].clips[0] == solid)
        #expect(t.tracks[1].clips[0] == audio)
    }

    @Test func refusesInvalidAndUnknownWithoutChange() {
        var (p, id) = project([videoClip()])
        let before = p
        #expect(throws: EditError.invalidFormat) { try p.changeFormat(of: id, to: fmt(0, 1920), mode: .fill) }
        #expect(throws: EditError.timelineNotFound) { try p.changeFormat(of: UUID(), to: fmt(1080, 1920), mode: .fill) }
        #expect(p == before)
    }

    @Test func undoRestoresSnapshot() throws {
        let (p0, id) = project([videoClip(position: Vec2(10, 10))])
        var h = History(p0)
        try h.commit("Change Format") { try $0.changeFormat(of: id, to: fmt(1080, 1920), mode: .fill) }
        #expect(h.current != p0)
        let undone = h.undo()
        #expect(undone)
        #expect(h.current == p0)
    }

    // MARK: Text

    @Test func textKeepsScaleMovesRelativelyAndStaysInSafeArea() throws {
        // Lower third at y = 400 in 1080 high: relative 0.37 of the height. 600 x 100 block.
        let c = textClip(position: Vec2(500, 400))
        var (p, id) = project([c])
        try p.changeFormat(of: id, to: fmt(1080, 1920), mode: .fill) { _ in SequenceConform.TextBlock(width: 600, height: 100) }
        let n = try #require(p.timeline(id)).tracks[0].clips[0]
        #expect(close(n.animation.scale.value, Vec2(1, 1)))
        // x: 500 * 1080/1920 = 281.25, but the block (half 300) must end at 432 -> 132. y: 400 * 1920/1080 = 711.1, fits (768 - 50).
        #expect(close(n.animation.position.value.x, 432 - 300))
        #expect(close(n.animation.position.value.y, 400 * 1920.0 / 1080.0))
    }

    @Test func oversizedTextShrinksToSafeArea() throws {
        let c = textClip(position: .zero, scale: Vec2(1, 1))
        var (p, id) = project([c])
        try p.changeFormat(of: id, to: fmt(1080, 1920), mode: .fit) { _ in SequenceConform.TextBlock(width: 1728, height: 200) }
        let n = try #require(p.timeline(id)).tracks[0].clips[0]
        // Safe width 864 of a 1728 block: half size.
        #expect(close(n.animation.scale.value, Vec2(0.5, 0.5)))
        #expect(close(n.animation.position.value, .zero))
    }

    @Test func textWithoutSizeOnlyMovesRelatively() throws {
        let c = textClip(position: Vec2(800, 300))
        var (p, id) = project([c])
        try p.changeFormat(of: id, to: fmt(1080, 1920), mode: .fill)
        let n = try #require(p.timeline(id)).tracks[0].clips[0]
        #expect(close(n.animation.position.value, Vec2(800 * 1080.0 / 1920.0, 300 * 1920.0 / 1080.0)))
        #expect(close(n.animation.scale.value, Vec2(1, 1)))
    }

    @Test func animatedTextPositionScaledPerAxisNotClamped() throws {
        var c = textClip()
        // Slide in from off screen: the key outside the frame must survive.
        c.animation.position.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(-1920, 0)),
                                                          Keyframe(time: s(1), value: Vec2(0, 270))])
        var (p, id) = project([c])
        try p.changeFormat(of: id, to: fmt(1080, 1920), mode: .fill) { _ in SequenceConform.TextBlock(width: 400, height: 100) }
        let keys = try #require(p.timeline(id)).tracks[0].clips[0].animation.position.track.keys
        #expect(close(keys[0].value, Vec2(-1080, 0)))
        #expect(close(keys[1].value, Vec2(0, 480)))
    }

    @Test func textClampAccountsForAnchorAndInkOffset() throws {
        // Scale 0.5, anchor (100, 0) layer px, ink center 40 px right of the block center: the block center on screen is
        // position + ink * (1 - s) - anchor * s = position + 20 - 50 = position - 30 (x).
        var c = textClip(position: Vec2(1000, 0), scale: Vec2(0.5, 0.5))
        c.animation.anchor = AnimatedProperty(Vec2(100, 0))
        var (p, id) = project([c])
        try p.changeFormat(of: id, to: fmt(1920, 1080), mode: .fill) {
            _ in SequenceConform.TextBlock(width: 400, height: 100, inkOffset: Vec2(40, 0))
        }
        let n = try #require(p.timeline(id)).tracks[0].clips[0]
        // Safe half width 768, block half 100: center may reach 668, so position = 668 + 30.
        #expect(close(n.animation.position.value.x, 698))
    }

    @Test func deliveryTargetClearedWhenOrientationFlips() throws {
        var (p, id) = project([videoClip()])
        p.timelines[0].deliveryTarget = DeliveryTarget(platform: .youtube)
        try p.changeFormat(of: id, to: fmt(1440, 1080), mode: .fill)
        #expect(p.timeline(id)?.deliveryTarget == DeliveryTarget(platform: .youtube))
        let dup = try p.duplicateSequence(id, as: fmt(1080, 1920), mode: .fill)
        #expect(p.timeline(dup)?.deliveryTarget == nil)
        #expect(p.timeline(id)?.deliveryTarget == DeliveryTarget(platform: .youtube))
        try p.changeFormat(of: id, to: fmt(1080, 1080), mode: .fill)
        #expect(p.timeline(id)?.deliveryTarget == nil)
        // Portrait to portrait keeps it.
        p.timelines[0].deliveryTarget = DeliveryTarget(platform: .tiktok)
        try p.changeFormat(of: id, to: fmt(1080, 1350), mode: .fill)
        #expect(p.timeline(id)?.deliveryTarget == DeliveryTarget(platform: .tiktok))
    }

    @Test func duplicateRegeneratesMarkerAndCaptionIDs() throws {
        var (p, id) = project([videoClip()])
        p.timelines[0].markers = [Marker(time: s(1), name: "m")]
        let item = CaptionItem(lines: ["Hi"], range: TimeRange(start: .zero, duration: s(1)))
        p.timelines[0].captionTracks = [CaptionTrack(name: "C", items: [item], styleRef: "s")]
        let src = try #require(p.timeline(id))
        let dupID = try p.duplicateSequence(id, as: fmt(1080, 1920), mode: .fill)
        let d = try #require(p.timeline(dupID))
        #expect(d.markers.count == 1 && d.markers[0].id != src.markers[0].id && d.markers[0].name == "m")
        let ct = try #require(d.captionTracks.first)
        #expect(ct.id != src.captionTracks[0].id && ct.styleRef == "s" && ct.name == "C")
        #expect(ct.items.count == 1 && ct.items[0].id != item.id && ct.items[0].lines == ["Hi"])
    }

    // MARK: Duplicate as Format

    @Test func duplicateAsFormatCopiesWithFreshIDs() throws {
        var a = videoClip(start: 0), b = videoClip(start: 5)
        let link = UUID()
        a.link = link
        var audio = Clip(name: "a", media: a.media, kind: .audio, source: a.source, start: .zero)
        audio.link = link
        let title = textClip(position: Vec2(0, 300))
        var (p, id) = project([a, b, title], audio: [audio])
        p.timelines[0].tracks[0].transitions = [Transition(kind: .crossDissolve, duration: s(1), outgoing: a.id, incoming: b.id)]
        let original = try #require(p.timeline(id))
        let newID = try p.duplicateSequence(id, as: fmt(1080, 1920), mode: .fill)
        #expect(p.timelines.count == 2)
        #expect(p.timeline(id) == original)
        let d = try #require(p.timeline(newID))
        #expect(d.name == "Main 9:16")
        #expect(d.format.width == 1080 && d.format.height == 1920 && d.format.frameDuration == fd)
        let oldClipIDs = Set(original.tracks.flatMap(\.clips).map(\.id))
        let newClips = d.tracks.flatMap(\.clips)
        #expect(newClips.count == 4)
        #expect(Set(newClips.map(\.id)).isDisjoint(with: oldClipIDs))
        #expect(Set(d.tracks.map(\.id)).isDisjoint(with: Set(original.tracks.map(\.id))))
        // Link kept as a pair, but a fresh group.
        let v0 = d.tracks[0].clips[0], a0 = d.tracks[1].clips[0]
        #expect(v0.link != nil && v0.link == a0.link && v0.link != link)
        // Transition follows the new clip IDs.
        let tr = try #require(d.tracks[0].transitions.first)
        #expect(tr.outgoing == v0.id && tr.incoming == d.tracks[0].clips[1].id)
        // Generator's media is its own ID.
        let g = d.tracks[0].clips[2]
        #expect(g.isGenerator && g.media == g.id)
        #expect(close(v0.animation.scale.value.x, 1920.0 / 1080.0))
        #expect(close(g.animation.position.value.y, 300 * 1920.0 / 1080.0))
        // In the project bins.
        #expect(p.timelines.contains { $0.id == newID })
    }

    @Test func duplicateNameAvoidsCollisionAndUsesCustomName() throws {
        var (p, id) = project([videoClip()])
        let one = try p.duplicateSequence(id, as: fmt(1080, 1920), mode: .fill)
        let two = try p.duplicateSequence(id, as: fmt(1080, 1920), mode: .fill)
        let three = try p.duplicateSequence(id, as: fmt(1080, 1080), mode: .fit, name: "Square cut")
        #expect(p.timeline(one)?.name == "Main 9:16")
        #expect(p.timeline(two)?.name == "Main 9:16 2")
        #expect(p.timeline(three)?.name == "Square cut")
    }

    @Test func aspectLabelOfCustomSize() {
        #expect(SequenceConform.aspectLabel(width: 1920, height: 1080) == "16:9")
        #expect(SequenceConform.aspectLabel(width: 1080, height: 1350) == "4:5")
        #expect(SequenceConform.aspectLabel(width: 1000, height: 700) == "1000×700")
    }
}
