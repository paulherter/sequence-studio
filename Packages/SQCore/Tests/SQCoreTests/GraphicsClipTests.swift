import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct GraphicsClipTests {
    private func project() -> (Project, Timeline.ID, Track.ID) {
        let v1 = Track(kind: .video), v2 = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, v2, Track(kind: .audio)])
        return (Project(name: "P", timelines: [t]), t.id, v2.id)
    }

    private func clip(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) -> Clip {
        p.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    /// A rectangle layer `w` x `h` at `pos`.
    private func rect(_ w: Double, _ h: Double, at pos: Vec2) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.setShapeSize(width: w, height: h)
        l.animation.position = AnimatedProperty(pos)
        return l
    }

    private func bounds(_ d: GraphicsDocument, _ id: UUID) -> GraphicsRect {
        d.bounds(of: id, atLocal: .zero)!
    }

    // MARK: Model and clip

    @Test func newGraphicsClipIsAGeneratorWithLayers() throws {
        var (p, tl, v2) = project()
        let id = try p.addGraphicsClip(in: tl, at: s(1), track: v2, duration: s(5))
        let c = clip(p, tl, id)
        #expect(c.isGraphics && c.isGenerator)
        #expect(c.name == "Graphic")
        #expect(c.graphics?.layers.isEmpty == true)
        #expect(c.timeline == TimeRange(start: s(1), duration: s(5)))
        #expect(p.containsGraphicsClips)
    }

    @Test func addRemoveAndUndoableEditsGoThroughOneMutation() throws {
        var (p, tl, v2) = project()
        let id = try p.addGraphicsClip(in: tl, at: .zero, track: v2, duration: s(5))
        let a = try p.addGraphicsLayer(.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080), to: id)
        let b = try p.addGraphicsLayer(.shape(.ellipse, canvasWidth: 1920, canvasHeight: 1080), to: id)
        #expect(clip(p, tl, id).graphics!.layers.map(\.id) == [a, b])
        #expect(clip(p, tl, id).graphics!.layers[1].name == "Ellipse")
        try p.editGraphics(clipID: id) { $0.remove([a]) }
        #expect(clip(p, tl, id).graphics!.layers.map(\.id) == [b])
        #expect(throws: EditError.clipNotFound) { try p.editGraphics(clipID: UUID()) { _ in } }
    }

    @Test func lockedTrackRefusesEdits() throws {
        var (p, tl, v2) = project()
        let id = try p.addGraphicsClip(in: tl, at: .zero, track: v2, duration: s(5))
        try p.edit(tl) { $0.tracks[1].isLocked = true }
        #expect(throws: EditError.trackLocked) { try p.editGraphics(clipID: id) { _ in } }
    }

    @Test func roundTripsThroughCodable() throws {
        var d = GraphicsDocument()
        let r = d.add(rect(100, 50, at: Vec2(10, 20)))
        let path = d.add(GraphicsLayer.path(canvasPoints: [Vec2(0, 0), Vec2(100, 0), Vec2(100, 40)], closed: false,
                                             color: .white, strokeWidth: 6))
        let t = d.add(GraphicsLayer.text(GeneratorRef(kind: GeneratorRef.text, payload: Data("x".utf8)), name: "Title"))
        _ = d.group([r, path], name: "Box")
        var c = Clip(name: "G", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero,
                     generator: .graphicsClip)
        c.graphics = d
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(back.graphics?.layer(t)?.name == "Title")
        // A plain clip writes no graphics key.
        let plain = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero)
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("graphics"))
    }

    @Test func projectFileWritesV42OnlyWithGraphics() throws {
        var (p, tl, v2) = project()
        #expect(ProjectFile.writtenVersion(for: p) < 42)
        _ = try p.addGraphicsClip(in: tl, at: .zero, track: v2, duration: s(2))
        #expect(ProjectFile.currentVersion >= 42)
        #expect(ProjectFile.writtenVersion(for: p) == 42)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.timelines == p.timelines)
    }

    // MARK: Order and groups

    @Test func reorderMovesLayersAndKeepsRelativeOrder() {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero)), b = d.add(rect(10, 10, at: .zero)), c = d.add(rect(10, 10, at: .zero))
        d.reorder([a], .front)
        #expect(d.layers.map(\.id) == [b, c, a])
        d.reorder([a], .backward)
        #expect(d.layers.map(\.id) == [b, a, c])
        d.reorder([a, c], .back)
        #expect(d.layers.map(\.id) == [a, c, b])
        d.reorder([b], .forward)                               // already on top
        #expect(d.layers.map(\.id) == [a, c, b])
        d.move([b], toIndex: 0)
        #expect(d.layers.map(\.id) == [b, a, c])
    }

    @Test func groupMakesMembersContiguousAndMovesThemTogether() {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero)), b = d.add(rect(10, 10, at: .zero)), c = d.add(rect(10, 10, at: .zero))
        let g = d.group([a, c], name: "G")!
        #expect(d.layers.map(\.id) == [b, a, c])                // members gathered at the topmost member
        #expect(d.layers.filter { $0.group == g }.count == 2)
        // Selecting one member reorders and moves the whole group.
        d.reorder([a], .back)
        #expect(d.layers.map(\.id) == [a, c, b])
        d.translate([c], by: Vec2(5, -3))
        #expect(d.layer(a)!.animation.position.value == Vec2(5, -3))
        #expect(d.layer(b)!.animation.position.value == .zero)
        d.ungroup(g)
        #expect(d.groups.isEmpty && d.layers.allSatisfy { $0.group == nil })
        // Fewer than two layers: no group.
        #expect(d.group([a], name: "X") == nil)
    }

    @Test func removingAllMembersDropsTheGroupAndDuplicateGivesFreshIDs() {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero)), b = d.add(rect(10, 10, at: .zero))
        _ = d.group([a, b], name: "G")
        let copies = d.duplicate([a])
        #expect(copies.count == 1 && copies[0] != a)
        #expect(d.layers.count == 3)
        #expect(d.layers.firstIndex { $0.id == copies[0] } == 1)   // right above the original
        #expect(d.layer(copies[0])?.group == nil)
        d.remove([a, b])
        #expect(d.groups.isEmpty)
    }

    @Test func lockedLayersDoNotMove() {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero))
        d.update(a) { $0.isLocked = true }
        d.translate([a], by: Vec2(5, 5))
        #expect(d.layer(a)!.animation.position.value == .zero)
    }

    // MARK: Bounds, align, distribute

    @Test func boundsFollowScaleRotationAndAnchor() {
        var d = GraphicsDocument()
        let a = d.add(rect(100, 50, at: Vec2(10, 20)))
        #expect(bounds(d, a) == GraphicsRect(minX: -40, minY: -5, maxX: 60, maxY: 45))
        d.update(a) { $0.animation.scale = AnimatedProperty(Vec2(2, 2)) }
        #expect(bounds(d, a) == GraphicsRect(minX: -90, minY: -30, maxX: 110, maxY: 70))
        d.update(a) { $0.animation.scale = AnimatedProperty(Vec2(1, 1)); $0.animation.rotation = AnimatedProperty(90) }
        let r = bounds(d, a)
        #expect(abs(r.width - 50) < 1e-9 && abs(r.height - 100) < 1e-9)
        // Anchor at the right edge: the right edge sits on the position.
        d.update(a) { $0.animation.rotation = AnimatedProperty(0); $0.animation.anchor = AnimatedProperty(Vec2(50, 0)) }
        #expect(bounds(d, a).maxX == 10)
    }

    @Test func singleLayerAlignsToTheCanvas() {
        var d = GraphicsDocument()
        let a = d.add(rect(100, 50, at: Vec2(10, 20)))
        let canvas = Vec2(1920, 1080)
        d.align([a], .left, canvas: canvas)
        #expect(bounds(d, a).minX == -960)
        d.align([a], .bottom, canvas: canvas)
        #expect(bounds(d, a).maxY == 540)
        d.align([a], .centerX, canvas: canvas)
        d.align([a], .centerY, canvas: canvas)
        #expect(d.layer(a)!.animation.position.value == .zero)
    }

    @Test func severalLayersAlignToTheirSelectionBounds() {
        var d = GraphicsDocument()
        let a = d.add(rect(100, 50, at: Vec2(0, 0))), b = d.add(rect(40, 40, at: Vec2(300, 100)))
        d.align([a, b], .right, canvas: Vec2(1920, 1080))
        #expect(bounds(d, a).maxX == 320 && bounds(d, b).maxX == 320)
        d.align([a, b], .top, canvas: Vec2(1920, 1080))
        #expect(bounds(d, a).minY == -25 && bounds(d, b).minY == -25)
    }

    @Test func alignMovesAKeyedPositionWithAllItsKeys() {
        var d = GraphicsDocument()
        var l = rect(100, 100, at: .zero)
        l.animation.position.track.insert(Keyframe(time: .zero, value: Vec2(0, 0)))
        l.animation.position.track.insert(Keyframe(time: s(1), value: Vec2(200, 0)))
        let a = d.add(l)
        d.align([a], .left, canvas: Vec2(1920, 1080), atLocal: .zero)
        let keys = d.layer(a)!.animation.position.track.keys.map(\.value)
        #expect(keys == [Vec2(-910, 0), Vec2(-710, 0)])
    }

    @Test func groupsAlignAsOneUnit() {
        var d = GraphicsDocument()
        let a = d.add(rect(100, 100, at: Vec2(0, 0))), b = d.add(rect(100, 100, at: Vec2(200, 0)))
        _ = d.group([a, b], name: "G")
        d.align([a], .left, canvas: Vec2(1920, 1080))            // one unit: aligns to the canvas, spacing kept
        #expect(bounds(d, a).minX == -960 && bounds(d, b).minX == -760)
    }

    @Test func distributeEqualisesGaps() {
        var d = GraphicsDocument()
        let a = d.add(rect(100, 10, at: Vec2(0, 0)))       // 50 ... -50
        let b = d.add(rect(20, 10, at: Vec2(70, 0)))       // 60 ... 80
        let c = d.add(rect(100, 10, at: Vec2(400, 0)))     // 350 ... 450
        d.distribute([c, a, b], .horizontal)
        // span -50...450, widths 220, gaps (500 - 220) / 2 = 140
        #expect(bounds(d, b).minX == 190)
        #expect(bounds(d, a).minX == -50 && bounds(d, c).maxX == 450)
    }

    @Test func textBoundsComeFromTheMeasure() {
        var d = GraphicsDocument()
        let t = d.add(GraphicsLayer.text(GeneratorRef(kind: GeneratorRef.text, payload: Data()), name: "T"))
        d.update(t) { $0.animation.position = AnimatedProperty(Vec2(10, 0)) }
        let measure: GraphicsTextMeasure = { _, _ in GraphicsRect(minX: -100, minY: 200, maxX: 100, maxY: 260) }
        #expect(d.bounds(of: t, atLocal: .zero, text: measure) == GraphicsRect(minX: -90, minY: 200, maxX: 110, maxY: 260))
        #expect(d.bounds(of: t, atLocal: .zero) == nil)
    }

    @Test func pathLayerNormalisesItsPointsAroundTheirCentre() {
        let l = GraphicsLayer.path(canvasPoints: [Vec2(100, 100), Vec2(300, 100), Vec2(300, 200)], closed: true,
                                   color: .white, strokeWidth: 4)
        #expect(l.animation.position.value == Vec2(200, 150))
        guard case .path(let pts, let closed) = l.content else { Issue.record("not a path"); return }
        #expect(closed && pts == [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)])
        let style = l.shapeStyle(atLocal: .zero)!
        #expect(style.width == 200 && style.height == 100)
        #expect(style.path == pts && style.fill != nil)
    }

    // MARK: Keyframes

    @Test func setValueKeysOnlyAnimatedProperties() {
        var p = AnimatedProperty(1.0)
        p.set(2, atLocal: s(1))
        #expect(p.value == 2 && !p.isAnimated)
        p.toggleKeyframing(atLocal: s(1))
        #expect(p.track.keys.map(\.value) == [2])
        p.set(5, atLocal: s(2))
        #expect(p.track.keys.map(\.value) == [2, 5])
        p.set(6, atLocal: s(2))                                       // replaces the key there, same id
        #expect(p.track.keys.count == 2 && p.value(atLocal: s(2)) == 6)
        p.toggleKeyframing(atLocal: s(2))                             // stopwatch off: value at the playhead stays
        #expect(!p.isAnimated && p.value == 6)
    }

    // MARK: Evaluation

    @Test func evaluationExpandsVisibleLayersIntoAGroupOfTheClip() throws {
        var (p, tl, v2) = project()
        let id = try p.addGraphicsClip(in: tl, at: s(1), track: v2, duration: s(4))
        var bottom = rect(100, 50, at: Vec2(10, 0))
        bottom.animation.opacity.track.insert(Keyframe(time: .zero, value: 0))
        bottom.animation.opacity.track.insert(Keyframe(time: s(2), value: 1))
        let a = try p.addGraphicsLayer(bottom, to: id)
        let hidden = try p.addGraphicsLayer(rect(10, 10, at: .zero), to: id)
        let t = try p.addGraphicsLayer(.text(GeneratorRef(kind: GeneratorRef.text, payload: Data("t".utf8)), name: "T"), to: id)
        try p.editGraphics(clipID: id) { $0.update(hidden) { $0.isVisible = false } }
        var c = clip(p, tl, id)
        c.animation.position = AnimatedProperty(Vec2(0, 300))
        try p.edit(tl) { try $0.replaceClip(c) }

        let layers = p.timeline(tl)!.videoLayers(at: s(2))
        #expect(layers.map(\.clip) == [a, t])
        #expect(layers.allSatisfy { $0.groups.count == 1 && $0.groups[0].clip == id })
        #expect(layers[0].groups[0].transform.position == Vec2(0, 300))
        #expect(layers[0].groups[0].format.width == p.timeline(tl)!.format.width)
        #expect(layers[0].transform.position == Vec2(10, 0))
        #expect(abs(layers[0].transform.opacity - 0.5) < 1e-9)       // local 1 s of a 0...2 s fade
        #expect(layers[0].generator?.kind == GeneratorRef.shape)
        #expect(layers[0].shape?.width == 100)
        #expect(layers[1].generator?.kind == GeneratorRef.text)
        #expect(layers[1].clipDuration == s(4))
        #expect(layers[1].localTime == s(1))
        // An empty or hidden graphic draws nothing; outside the clip nothing either.
        #expect(p.timeline(tl)!.videoLayers(at: s(6)).isEmpty)
    }

    @Test func layerEffectsAndBlendModeReachTheRequest() throws {
        var (p, tl, v2) = project()
        let id = try p.addGraphicsClip(in: tl, at: .zero, track: v2, duration: s(4))
        var l = rect(100, 50, at: .zero)
        l.blendMode = .multiply
        l.effects.append(ClipEffect(kind: ClipEffect.gaussianBlurKind,
                                    parameters: ClipEffect.defaultParameters(for: ClipEffect.gaussianBlurKind)
                                        .merging([ClipEffect.blurrinessKey: AnimatedProperty(12)]) { $1 }))
        _ = try p.addGraphicsLayer(l, to: id)
        let r = p.timeline(tl)!.videoLayers(at: s(1))
        #expect(r.count == 1 && r[0].blendMode == .multiply && r[0].effects.blur > 0)
    }
}
