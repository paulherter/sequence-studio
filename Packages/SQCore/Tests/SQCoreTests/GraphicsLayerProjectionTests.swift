import Foundation
import Testing
@testable import SQCore

/// Controls shows one item of a graphics clip as a plain clip; edits go back to that item only.
@Suite struct GraphicsLayerProjectionTests {
    private func graphic() -> (Clip, UUID, UUID) {
        var doc = GraphicsDocument()
        var a = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        a.name = "Box"
        a.animation.position = AnimatedProperty(Vec2(10, 20))
        var b = GraphicsLayer.shape(.ellipse, canvasWidth: 1920, canvasHeight: 1080)
        b.name = "Dot"
        let ia = doc.add(a), ib = doc.add(b)
        var c = Clip(name: "Graphic", media: UUID(), kind: .video,
                     source: TimeRange(start: .zero, duration: Time(5, 1)), start: Time(2, 1),
                     generator: GeneratorRef.graphicsClip)
        c.graphics = doc
        return (c, ia, ib)
    }

    @Test func projectionIsAPlainClipWithTheItemsMotionAndEffects() throws {
        let (host, a, _) = graphic()
        let p = try #require(host.graphicsItemProjection(a))
        #expect(p.id == host.id && p.start == host.start && p.duration == host.duration)
        #expect(p.name == "Box")
        #expect(p.generator?.shapeKind == .rectangle)
        #expect(p.graphics == nil && !p.isGraphics)
        #expect(p.animation == host.graphics?.layer(a)?.animation)
        #expect(p.effects == host.graphics?.layer(a)?.effects)
    }

    @Test func unknownItemOrPlainClipHasNoProjection() {
        let (host, _, _) = graphic()
        #expect(host.graphicsItemProjection(UUID()) == nil)
        var plain = host
        plain.generator = nil
        #expect(plain.graphicsItemProjection(UUID()) == nil)
    }

    @Test func editsGoBackToTheItemOnly() throws {
        let (host, a, b) = graphic()
        var p = try #require(host.graphicsItemProjection(a))
        p.animation.rotation = AnimatedProperty(45.0)
        p.blendMode = .multiply
        let next = host.applyingItemProjection(p, layer: a)
        #expect(next.graphics?.layer(a)?.animation.rotation.value == 45)
        #expect(next.graphics?.layer(a)?.blendMode == .multiply)
        #expect(next.graphics?.layer(b) == host.graphics?.layer(b))
        #expect(next.animation == host.animation && next.effects == host.effects)
        #expect(next.graphicsItemProjection(a) == p)
    }

    @Test func keysOfAnItemStayOnTheItem() throws {
        let (host, a, _) = graphic()
        var p = try #require(host.graphicsItemProjection(a))
        p.animation.opacity.track.keys = [Keyframe(time: Time(1, 1), value: 0.5)]
        let next = host.applyingItemProjection(p, layer: a)
        #expect(next.graphics?.layer(a)?.animation.opacity.isAnimated == true)
        #expect(next.animation.opacity.isAnimated == false)
    }

    @Test func lockedItemIgnoresEdits() throws {
        var (host, a, _) = graphic()
        host.graphics?.layers[0].isLocked = true
        var p = try #require(host.graphicsItemProjection(a))
        p.animation.rotation = AnimatedProperty(10.0)
        #expect(host.applyingItemProjection(p, layer: a) == host)
    }

    @Test func pickerListsFrontFirstAndShowsOnlyASingleExistingItem() throws {
        let (host, a, b) = graphic()
        let doc = try #require(host.graphics)
        #expect(doc.itemPickerEntries.map(\.id) == [b, a])
        #expect(doc.itemPickerEntries.map(\.name) == ["Dot", "Box"])
        #expect(doc.shownItem(selection: [a]) == a)
        #expect(doc.shownItem(selection: []) == nil)
        #expect(doc.shownItem(selection: [a, b]) == nil)
        #expect(doc.shownItem(selection: [UUID()]) == nil)
    }

    @Test func textOfATextItemGoesBack() throws {
        var (host, _, _) = graphic()
        let t = GraphicsLayer.text(GeneratorRef(kind: GeneratorRef.text, payload: Data([1])))
        host.graphics?.layers.append(t)
        var p = try #require(host.graphicsItemProjection(t.id))
        #expect(p.generator?.kind == GeneratorRef.text)
        p.generator = GeneratorRef(kind: GeneratorRef.text, payload: Data([2]))
        let next = host.applyingItemProjection(p, layer: t.id)
        #expect(next.graphics?.layer(t.id)?.content == .text(ref: p.generator!))
    }
}
