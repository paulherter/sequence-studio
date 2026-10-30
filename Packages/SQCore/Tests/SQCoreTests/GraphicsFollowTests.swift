import Foundation
import Testing
@testable import SQCore

// G11 Follow: a layer's edges stay at another layer's (or the frame's) edges. A shape following on both edges of an axis
// takes the target's extent plus padding; a text layer only moves. Resolution runs in dependency order; cycles, chains
// deeper than `GraphicsDocument.maxFollowDepth` and unknown targets are ignored (the layer draws as authored).

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let canvas = Vec2(1920, 1080)

/// A rectangle `w` x `h` at `pos`.
private func rect(_ w: Double, _ h: Double, at pos: Vec2 = .zero, name: String = "Rect") -> GraphicsLayer {
    var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    l.setShapeSize(width: w, height: h)
    l.animation.position = AnimatedProperty(pos)
    l.name = name
    return l
}

/// A fake text payload: its measured box is 10 px per payload byte wide and 40 px high, centered on the canvas center.
private func textLayer(_ s: String, at pos: Vec2 = .zero) -> GraphicsLayer {
    var l = GraphicsLayer.text(GeneratorRef(kind: GeneratorRef.text, payload: Data(s.utf8)))
    l.animation.position = AnimatedProperty(pos)
    return l
}

private let measure: GraphicsTextMeasure = { ref, _ in
    let w = Double(ref.payload.count) * 10
    return GraphicsRect(minX: -w / 2, minY: -20, maxX: w / 2, maxY: 20)
}

private func near(_ a: GraphicsRect?, _ b: GraphicsRect, _ eps: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps && abs(a.maxX - b.maxX) < eps && abs(a.maxY - b.maxY) < eps
}

private func resolved(_ d: GraphicsDocument, _ t: Time = .zero) -> GraphicsDocument {
    d.resolvingFollow(atLocal: t, canvas: canvas, text: measure)
}

private func box(_ d: GraphicsDocument, _ id: UUID, _ t: Time = .zero) -> GraphicsRect? {
    resolved(d, t).bounds(of: id, atLocal: t, text: measure)
}

@Suite struct GraphicsFollowTests {
    // MARK: Model

    @Test func defaultsAndCoding() throws {
        let l = rect(100, 50)
        #expect(l.follow == nil)
        // No follow: the key is absent, so the bytes equal what a v62 build wrote.
        let json = String(decoding: try JSONEncoder().encode(l), as: UTF8.self)
        #expect(!json.contains("follow"))
        var f = l
        f.follow = GraphicsFollow(target: .layer(id: UUID()), edges: [.left, .bottom], padding: 12)
        let back = try JSONDecoder().decode(GraphicsLayer.self, from: try JSONEncoder().encode(f))
        #expect(back == f)
        let frame = GraphicsFollow(target: .frame)
        #expect(frame.edges == .all && frame.padding == 0)
        #expect(try JSONDecoder().decode(GraphicsFollow.self, from: try JSONEncoder().encode(frame)) == frame)
    }

    // MARK: Shapes grow, text moves

    @Test func shapeFollowingTextGrowsWithMeasuredBoundsPlusPadding() {
        let text = textLayer("Hello", at: Vec2(100, 50))       // 50 x 40 at (100, 50)
        var bg = rect(10, 10, at: Vec2(-500, -300))
        bg.follow = GraphicsFollow(target: .layer(id: text.id), padding: 24)
        var d = GraphicsDocument(layers: [bg, text])
        #expect(near(box(d, bg.id), GraphicsRect(minX: 75 - 24, minY: 30 - 24, maxX: 125 + 24, maxY: 70 + 24)))
        // Longer text: the box grows with it.
        d.update(text.id) { $0.content = .text(ref: GeneratorRef(kind: GeneratorRef.text, payload: Data("Hello world".utf8))) }
        #expect(near(box(d, bg.id), GraphicsRect(minX: 45 - 24, minY: 30 - 24, maxX: 155 + 24, maxY: 70 + 24)))
        // The stored layer is untouched: only the evaluated picture follows.
        #expect(d.layer(bg.id)?.animation.position.value == Vec2(-500, -300))
    }

    @Test func oneEdgeMovesWithoutResizing() {
        let a = rect(200, 100, at: .zero)                       // -100...100, -50...50
        var b = rect(40, 20, at: Vec2(300, 300))
        b.follow = GraphicsFollow(target: .layer(id: a.id), edges: [.left], padding: 10)
        let d = GraphicsDocument(layers: [a, b])
        // Left edge 10 px outside A's left edge; y and size unchanged.
        #expect(near(box(d, b.id), GraphicsRect(minX: -110, minY: 290, maxX: -70, maxY: 310)))
        var c = b
        c.follow = GraphicsFollow(target: .layer(id: a.id), edges: [.right, .bottom], padding: -10)
        let d2 = GraphicsDocument(layers: [a, c])
        // Negative padding = inside the target.
        #expect(near(box(d2, c.id), GraphicsRect(minX: 50, minY: 20, maxX: 90, maxY: 40)))
    }

    @Test func textOnlyMoves() {
        let shape = rect(400, 200, at: Vec2(-200, 100))          // -400...0, 0...200
        var t = textLayer("Hi", at: Vec2(500, 500))              // 20 x 40
        t.follow = GraphicsFollow(target: .layer(id: shape.id), padding: 24)
        let d = GraphicsDocument(layers: [shape, t])
        // Both edges on both axes: a text layer cannot stretch, it is centered on the target.
        #expect(near(box(d, t.id), GraphicsRect(minX: -210, minY: 80, maxX: -190, maxY: 120)))
        #expect(resolved(d).layer(t.id)?.animation.scale.value == Vec2(1, 1))
        var t2 = t
        t2.follow = GraphicsFollow(target: .layer(id: shape.id), edges: [.top], padding: -8)
        #expect(near(box(GraphicsDocument(layers: [shape, t2]), t2.id), GraphicsRect(minX: 490, minY: 8, maxX: 510, maxY: 48)))
    }

    @Test func frameTargetInsetsByPadding() {
        var bar = rect(10, 10)
        bar.follow = GraphicsFollow(target: .frame, padding: 48)
        var logo = rect(100, 60, at: .zero)
        logo.follow = GraphicsFollow(target: .frame, edges: [.right, .bottom], padding: 48)
        let d = GraphicsDocument(layers: [bar, logo])
        #expect(near(box(d, bar.id), GraphicsRect(minX: -912, minY: -492, maxX: 912, maxY: 492)))
        #expect(near(box(d, logo.id), GraphicsRect(minX: 812, minY: 432, maxX: 912, maxY: 492)))
        // Another canvas (a format variant): the pin follows it.
        let v = d.resolvingFollow(atLocal: .zero, canvas: Vec2(1080, 1920), text: nil)
        #expect(near(v.bounds(of: logo.id, atLocal: .zero), GraphicsRect(minX: 392, minY: 852, maxX: 492, maxY: 912)))
    }

    @Test func scaledFollowerKeepsItsScaleAndFitsTheExtent() {
        let a = rect(200, 100)
        var b = rect(10, 10, at: Vec2(400, 0))
        b.animation.scale = AnimatedProperty(Vec2(2, 0.5))
        b.follow = GraphicsFollow(target: .layer(id: a.id), padding: 0)
        let r = resolved(GraphicsDocument(layers: [a, b]))
        #expect(near(r.bounds(of: b.id, atLocal: .zero), GraphicsRect(minX: -100, minY: -50, maxX: 100, maxY: 50)))
        #expect(r.layer(b.id)?.shapeStyle(atLocal: .zero)?.width == 100)
        #expect(r.layer(b.id)?.shapeStyle(atLocal: .zero)?.height == 200)
    }

    @Test func lineKeepsItsThicknessAndPathsStretch() {
        let a = rect(300, 100)
        var line = GraphicsLayer.shape(.line, canvasWidth: 1920, canvasHeight: 1080)
        line.follow = GraphicsFollow(target: .layer(id: a.id), edges: [.left, .right, .bottom], padding: 0)
        var path = GraphicsLayer.path(canvasPoints: [Vec2(0, 0), Vec2(10, 20), Vec2(20, 0)], closed: true,
                                      color: EffectColor(red: 1, green: 0, blue: 0), strokeWidth: 2)
        path.follow = GraphicsFollow(target: .layer(id: a.id))
        let r = resolved(GraphicsDocument(layers: [a, line, path]))
        let lb = r.bounds(of: line.id, atLocal: .zero)!
        #expect(abs(lb.width - 300) < 1e-6 && abs(lb.maxY - 50) < 1e-6)
        #expect(r.layer(line.id)?.shapeStyle(atLocal: .zero)?.height == line.shapeStyle(atLocal: .zero)?.height)
        #expect(near(r.bounds(of: path.id, atLocal: .zero), GraphicsRect(minX: -150, minY: -50, maxX: 150, maxY: 50)))
    }

    @Test func keyedTargetIsFollowedAtEveryInstant() {
        var a = rect(100, 100)
        a.animation.position = AnimatedProperty(Vec2(0, 0))
        a.animation.position.track.insert(Keyframe(time: .zero, value: Vec2(0, 0)))
        a.animation.position.track.insert(Keyframe(time: s(2), value: Vec2(200, 0)))
        var b = rect(10, 10)
        b.follow = GraphicsFollow(target: .layer(id: a.id), padding: 5)
        let d = GraphicsDocument(layers: [a, b])
        #expect(near(box(d, b.id, .zero), GraphicsRect(minX: -55, minY: -55, maxX: 55, maxY: 55)))
        #expect(near(box(d, b.id, s(2)), GraphicsRect(minX: 145, minY: -55, maxX: 255, maxY: 55)))
    }

    // MARK: Resolution order and safety

    @Test func chainsResolveInDependencyOrderWhateverTheListOrder() {
        let a = textLayer("abcd", at: Vec2(0, 0))                // 40 x 40
        var b = rect(1, 1, name: "B")
        b.follow = GraphicsFollow(target: .layer(id: a.id), padding: 10)   // 60 x 60
        var c = rect(1, 1, name: "C")
        c.follow = GraphicsFollow(target: .layer(id: b.id), padding: 10)   // 80 x 80
        for order in [[c, b, a], [a, b, c], [b, c, a]] {
            let d = GraphicsDocument(layers: order)
            #expect(near(box(d, c.id), GraphicsRect(minX: -40, minY: -40, maxX: 40, maxY: 40)))
        }
    }

    @Test func cyclesAreIgnored() {
        var a = rect(100, 100, at: Vec2(-300, 0), name: "A")
        var b = rect(50, 50, at: Vec2(300, 0), name: "B")
        a.follow = GraphicsFollow(target: .layer(id: b.id))
        b.follow = GraphicsFollow(target: .layer(id: a.id))
        var self1 = rect(20, 20, at: Vec2(0, 300))
        self1.follow = GraphicsFollow(target: .layer(id: self1.id))
        // D follows a cycle member: the member draws as authored, D follows that.
        var d1 = rect(1, 1)
        d1.follow = GraphicsFollow(target: .layer(id: a.id), padding: 0)
        let d = GraphicsDocument(layers: [a, b, self1, d1])
        let r = resolved(d)
        #expect(r.layer(a.id) == a && r.layer(b.id) == b && r.layer(self1.id) == self1)
        #expect(near(r.bounds(of: d1.id, atLocal: .zero), GraphicsRect(minX: -350, minY: -50, maxX: -250, maxY: 50)))
    }

    @Test func chainsDeeperThanTheLimitAreIgnored() {
        var layers = [rect(100, 100, name: "root")]
        for k in 1...(GraphicsDocument.maxFollowDepth + 3) {
            var l = rect(1, 1, at: Vec2(Double(k) * 10, 0), name: "L\(k)")
            l.follow = GraphicsFollow(target: .layer(id: layers[k - 1].id), padding: 1)
            layers.append(l)
        }
        let d = GraphicsDocument(layers: layers.reversed())
        let r = resolved(d)
        let limit = GraphicsDocument.maxFollowDepth
        let deepest = layers[limit]
        let w = 100 + 2 * Double(limit)
        #expect(near(r.bounds(of: deepest.id, atLocal: .zero), GraphicsRect(minX: -w / 2, minY: -w / 2, maxX: w / 2, maxY: w / 2)))
        // Beyond the limit: as authored.
        for k in (limit + 1)..<layers.count { #expect(r.layer(layers[k].id) == layers[k]) }
    }

    @Test func unknownOrDeletedTargetUnpins() {
        var b = rect(40, 40, at: Vec2(10, 10))
        b.follow = GraphicsFollow(target: .layer(id: UUID()))
        #expect(resolved(GraphicsDocument(layers: [b])).layer(b.id) == b)
        let a = rect(100, 100)
        var c = rect(40, 40)
        c.follow = GraphicsFollow(target: .layer(id: a.id))
        var other = rect(40, 40)
        other.follow = GraphicsFollow(target: .frame)
        var d = GraphicsDocument(layers: [a, c, other])
        d.remove([a.id])
        #expect(d.layer(c.id)?.follow == nil)                  // deleting the target unpins the follower
        #expect(d.layer(other.id)?.follow == GraphicsFollow(target: .frame))
    }

    @Test func emptyTextTargetLeavesTheFollowerAsAuthored() {
        let t = textLayer("")
        var b = rect(40, 40, at: Vec2(10, 10))
        b.follow = GraphicsFollow(target: .layer(id: t.id))
        let none: GraphicsTextMeasure = { _, _ in nil }
        let r = GraphicsDocument(layers: [t, b]).resolvingFollow(atLocal: .zero, canvas: canvas, text: none)
        #expect(r.layer(b.id) == b)
    }

    @Test func noFollowReturnsTheDocumentUnchanged() {
        let d = GraphicsDocument(layers: [rect(10, 10), textLayer("x")])
        #expect(!d.hasFollow)
        #expect(resolved(d) == d)
        var e = d
        e.layers[0].follow = GraphicsFollow(target: .frame, edges: [])
        // A follow without edges changes nothing in the picture.
        #expect(resolved(e).layers[0].animation == e.layers[0].animation)
        #expect(resolved(e).layers[0].effects == e.layers[0].effects)
    }

    // MARK: Candidates (Follows popup)

    @Test func candidatesExcludeSelfAndCycles() {
        let a = rect(10, 10, name: "A")
        var b = rect(10, 10, name: "B")
        b.follow = GraphicsFollow(target: .layer(id: a.id))
        var c = rect(10, 10, name: "C")
        c.follow = GraphicsFollow(target: .layer(id: b.id))
        let d = GraphicsDocument(layers: [a, b, c])
        // A cannot follow B or C (both lead back to A); front first like the layer list.
        #expect(d.followCandidates(for: a.id).map(\.id).isEmpty)
        #expect(d.followCandidates(for: c.id).map(\.id) == [b.id, a.id])
        #expect(d.followCandidates(for: b.id).map(\.id) == [a.id])
        #expect(d.followCandidates(for: UUID()).isEmpty)
    }

    @Test func duplicateKeepsTheFollow() {
        let a = rect(10, 10)
        var b = rect(10, 10)
        b.follow = GraphicsFollow(target: .layer(id: a.id), padding: 3)
        var d = GraphicsDocument(layers: [a, b])
        let ids = d.duplicate([b.id])
        #expect(d.layer(ids[0])?.follow == b.follow)
    }

    @Test func duplicatingTargetAndFollowerTogetherRepinsTheCopies() throws {
        let title = textLayer("Title")
        var bg = rect(10, 10)
        bg.follow = GraphicsFollow(target: .layer(id: title.id), padding: 8)
        let other = rect(50, 50)
        var free = rect(5, 5)
        free.follow = GraphicsFollow(target: .layer(id: other.id))
        var d = GraphicsDocument(layers: [bg, title, other, free])
        let ids = d.duplicate([bg.id, title.id, free.id])
        let bgCopy = try #require(d.layer(ids[0])), titleCopy = ids[1]
        #expect(bgCopy.follow == GraphicsFollow(target: .layer(id: titleCopy), padding: 8))
        #expect(d.layer(bg.id)?.follow?.target == .layer(id: title.id))          // the original keeps its pin
        #expect(d.layer(ids[2])?.follow?.target == .layer(id: other.id))         // target outside the set stays
    }

    @Test func alignMeasuresWhatIsDrawnAndLeavesPinnedAxesToFollow() throws {
        let a = rect(200, 100, at: .zero)                          // -100...100
        var b = rect(40, 20, at: Vec2(600, 300))
        b.follow = GraphicsFollow(target: .layer(id: a.id), edges: [.left], padding: 10)   // drawn at minX -110
        let c = rect(20, 20, at: Vec2(400, -200))
        var d = GraphicsDocument(layers: [a, b, c])
        d.editingResolved(atLocal: .zero, canvas: canvas, text: measure) {
            $0.align([b.id, c.id], .left, canvas: canvas, atLocal: .zero, text: measure)
        }
        // C goes to B's drawn left edge (not its authored 580); B's x stays Follow's, its stored x is untouched.
        #expect(abs((box(d, c.id)?.minX ?? 0) - -110) < 1e-6)
        #expect(d.layer(b.id)?.animation.position.value.x == 600)
        d.editingResolved(atLocal: .zero, canvas: canvas, text: measure) {
            $0.align([b.id, c.id], .top, canvas: canvas, atLocal: .zero, text: measure)
        }
        // Top is not pinned: B moves there (its stored y changes), C stays the top-most.
        #expect(abs((box(d, b.id)?.minY ?? 0) - -210) < 1e-6)
        #expect(abs((box(d, c.id)?.minY ?? 0) - -210) < 1e-6)
    }

    @Test func aFollowerWhoseTargetHasNoSizeIsEditedLikeAnyLayer() {
        // The target is an empty text (no box): Follow does not move the follower, so a move on the "pinned" axis counts.
        let t = textLayer("")
        var b = rect(40, 40, at: Vec2(10, 10))
        b.follow = GraphicsFollow(target: .layer(id: t.id), edges: [.left, .top])
        let none: GraphicsTextMeasure = { _, _ in nil }
        var d = GraphicsDocument(layers: [t, b])
        d.editingResolved(atLocal: .zero, canvas: canvas, text: none) {
            $0.translate([b.id], by: Vec2(190, 90))
        }
        #expect(d.layer(b.id)?.animation.position.value == Vec2(200, 100))
    }

    @Test func resizeOfAStretchedFollowerKeepsTheStretchedSize() throws {
        let a = rect(200, 100)
        var b = rect(10, 10)
        b.follow = GraphicsFollow(target: .layer(id: a.id), edges: [.left, .right], padding: 5)   // width stretched, height free
        var d = GraphicsDocument(layers: [a, b])
        #expect(near(box(d, b.id), GraphicsRect(minX: -105, minY: -5, maxX: 105, maxY: 5)))
        d.editingResolved(atLocal: .zero, canvas: canvas, text: measure) {
            $0.resize(b.id, corner: .bottomRight, to: Vec2(300, 45), atLocal: .zero, text: measure)
        }
        // Height follows the drag from the drawn top edge (-5 -> 45 = 50); width stays Follow's.
        let r = try #require(box(d, b.id))
        #expect(abs(r.height - 50) < 1e-6 && abs(r.minX - -105) < 1e-6 && abs(r.maxX - 105) < 1e-6 && abs(r.minY - -5) < 1e-6)
        #expect(d.layer(b.id)?.shapeStyle(atLocal: .zero)?.width == 10)
    }

    @Test func rotatedShapeFollowerOnlyMoves() throws {
        let a = rect(200, 100, at: Vec2(300, 0))
        var b = rect(40, 20, at: Vec2(-500, 0))
        b.animation.rotation = AnimatedProperty(30)
        b.follow = GraphicsFollow(target: .layer(id: a.id), padding: 10)
        let r = resolved(GraphicsDocument(layers: [a, b]))
        let rb = try #require(r.layer(b.id))
        #expect(rb.shapeStyle(atLocal: .zero)?.width == 40 && rb.shapeStyle(atLocal: .zero)?.height == 20)
        let bb = try #require(r.bounds(of: b.id, atLocal: .zero, text: measure))
        #expect(abs(bb.midX - 300) < 1e-6 && abs(bb.midY) < 1e-6)
    }

    // MARK: Evaluation (monitor and export read the same requests)

    private func project(_ layers: [GraphicsLayer]) throws -> (Project, Timeline.ID) {
        let v1 = Track(kind: .video)
        let t = Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [v1])
        var p = Project(name: "P", timelines: [t])
        _ = try p.addGraphicsClip(in: t.id, at: .zero, track: v1.id, duration: s(5), layers: layers)
        return (p, t.id)
    }

    @Test func evaluationDrawsTheResolvedLayers() throws {
        let a = rect(200, 100, at: Vec2(100, 0))
        var b = rect(10, 10, at: Vec2(-600, 0))
        b.follow = GraphicsFollow(target: .layer(id: a.id), padding: 10)
        let (p, tl) = try project([b, a])
        let reqs = p.timeline(tl)!.videoLayers(at: s(1))
        let rb = try #require(reqs.first { $0.clip == b.id })
        #expect(rb.shape?.width == 220 && rb.shape?.height == 120)
        #expect(rb.transform.position == Vec2(100, 0))
        // Same picture as the resolved document (the Graphics overlay draws from it).
        let r = resolved(GraphicsDocument(layers: [b, a]), s(1))
        #expect(rb.shape == r.layer(b.id)?.shapeStyle(atLocal: s(1)))
    }

    @Test func layersWithoutFollowEvaluateIdentically() throws {
        let a = rect(200, 100, at: Vec2(100, 0))
        let b = rect(10, 10, at: Vec2(-600, 0))
        let (p0, tl0) = try project([b, a])
        var b2 = b
        b2.follow = GraphicsFollow(target: .layer(id: a.id), edges: [])
        let (p1, tl1) = try project([b2, a])
        let r0 = p0.timeline(tl0)!.videoLayers(at: s(1)), r1 = p1.timeline(tl1)!.videoLayers(at: s(1))
        #expect(r0.count == 2 && r1.count == 2)
        for (x, y) in zip(r0, r1) {
            #expect(x.transform == y.transform && x.shape == y.shape && x.effects == y.effects && x.clip == y.clip)
        }
    }
}

// Monitor drag of a pinned layer: the dragged axis is unpinned where the layer is drawn, the other axis stays pinned.
@Suite struct GraphicsFollowDragTests {
    private func setup() -> (GraphicsDocument, text: UUID, box: UUID) {
        var d = GraphicsDocument()
        let t = textLayer("Title")                       // 50 x 40 at the center
        var b = rect(10, 10, at: Vec2(300, 300), name: "Box")
        b.follow = GraphicsFollow(target: .layer(id: t.id), padding: 10)
        d.layers = [b, t]
        return (d, t.id, b.id)
    }

    private func drawn(_ d: GraphicsDocument, _ id: UUID) -> GraphicsRect {
        d.resolvingFollow(atLocal: .zero, canvas: canvas, text: measure).bounds(of: id, atLocal: .zero, text: measure)!
    }

    @Test func dragUnpinsTheMovedAxisAndKeepsTheDrawnBox() {
        var (d, _, box) = setup()
        let shown = drawn(d, box)
        d.moveEditingResolved([box], by: Vec2(40, 0), atLocal: .zero, canvas: canvas, text: measure)
        #expect(d.layer(box)?.follow?.edges == [.top, .bottom])       // x pinned off, y stays
        let after = drawn(d, box)
        #expect(abs(after.minX - (shown.minX + 40)) < 1e-6 && abs(after.maxX - (shown.maxX + 40)) < 1e-6)
        #expect(abs(after.minY - shown.minY) < 1e-6 && abs(after.maxY - shown.maxY) < 1e-6)
    }

    @Test func dragOnBothAxesDropsTheFollow() {
        var (d, _, box) = setup()
        d.moveEditingResolved([box], by: Vec2(5, 5), atLocal: .zero, canvas: canvas, text: measure)
        #expect(d.layer(box)?.follow == nil)
    }

    @Test func targetsAndFreeLayersJustMove() {
        var (d, text, box) = setup()
        d.moveEditingResolved([text], by: Vec2(7, 0), atLocal: .zero, canvas: canvas, text: measure)
        #expect(d.layer(text)?.animation.position.value == Vec2(7, 0))
        #expect(d.layer(box)?.follow?.edges == .all)
    }
}
