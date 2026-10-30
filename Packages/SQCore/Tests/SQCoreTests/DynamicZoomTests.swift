import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }
private let pic = Vec2(1920, 1080)
private let frame = Vec2(1920, 1080)

private func clip() -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
}

@Suite struct DynamicZoomTests {
    @Test func fullWindowIsIdentity() {
        let v = DynamicZoom.stageValues(for: .full, picture: pic)
        #expect(close(v.scalePercent, 100) && close(v.position.x, 0) && close(v.position.y, 0))
    }

    @Test func centredWindowScalesAboutTheCentre() {
        let v = DynamicZoom.stageValues(for: .centred(zoom: 2), picture: pic)
        #expect(close(v.scalePercent, 200) && close(v.position.x, 0) && close(v.position.y, 0))
    }

    @Test func cornerWindowShowsThatCorner() {
        let r = ZoomRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let v = DynamicZoom.stageValues(for: r, picture: pic)
        let k = v.scalePercent / 100
        // The picture's top-left corner lands on the frame's top-left, the window's bottom-right (picture center) on the frame's.
        #expect(close(k * -960 + v.position.x, -960) && close(k * -540 + v.position.y, -540))
        #expect(close(v.position.x, 960) && close(v.position.y, 540))
    }

    @Test func windowsAreKeptInsideThePicture() {
        let r = ZoomRect(x: 0.9, y: -0.2, width: 0.5, height: 0.5).clamped
        #expect(close(r.x, 0.5) && close(r.y, 0) && close(r.width, 0.5))
        #expect(ZoomRect(x: 0, y: 0, width: 0, height: 0).clamped.width == 0.01)
        #expect(ZoomRect(x: .nan, y: 0, width: .infinity, height: 1).clamped.width == 1)
    }

    @Test func effectHasEasedKeysAtClipStartAndEnd() throws {
        var c = clip()
        #expect(DynamicZoom.apply(to: &c, from: .full, to: .centred(zoom: 1.25), picture: pic))
        let e = try #require(c.effects.first)
        #expect(e.kind == ClipEffect.dynamicZoomKind && e.isTransformStage)
        let sc = try #require(e.parameters[ClipEffect.stageScaleKey])
        #expect(sc.track.keys.map(\.time) == [.zero, s(4)])
        #expect(close(sc.value(atLocal: .zero), 100) && close(sc.value(atLocal: s(4)), 125))
        let q = sc.value(atLocal: s(1))     // slow start: behind the linear 106.25
        #expect(q > 100 && q < 106.25)
        #expect(sc.track.keys.allSatisfy { $0.interpolation == .bezier })
    }

    @Test func linearEaseUsesLinearKeys() throws {
        var c = clip()
        DynamicZoom.apply(to: &c, from: .full, to: .centred(zoom: 2), picture: pic, ease: .linear)
        let sc = try #require(c.effects.first?.parameters[ClipEffect.stageScaleKey])
        #expect(close(sc.value(atLocal: s(2)), 150, 1e-6))
    }

    @Test func rendersAsStageOnTopOfMotionWithoutTouchingIt() {
        var c = clip()
        c.animation.scale = AnimatedProperty(Vec2(120, 120))
        let before = c.transform(at: s(2))
        DynamicZoom.apply(to: &c, from: .full, to: .centred(zoom: 2), picture: pic, ease: .linear)
        #expect(c.transform(at: s(2)) == before)
        let end = c.renderTransform(at: s(4), frame: frame)
        #expect(close(end.scale.x, before.scale.x * 2, 1e-9))
    }

    @Test func sameWindowsOrEmptyClipWriteNothing() {
        var c = clip()
        #expect(!DynamicZoom.apply(to: &c, from: .full, to: .full, picture: pic))
        #expect(c.effects.isEmpty)
        var z = clip()
        z.source = TimeRange(start: .zero, duration: .zero)
        #expect(!DynamicZoom.apply(to: &z, from: .full, to: .centred(zoom: 2), picture: pic))
    }

    @Test func secondRunReplacesTheStageKeepingItsID() throws {
        var c = clip()
        DynamicZoom.apply(to: &c, from: .full, to: .centred(zoom: 2), picture: pic)
        let id = c.effects[0].id
        DynamicZoom.apply(to: &c, from: .centred(zoom: 2), to: .full, picture: pic)
        #expect(c.effects.count == 1 && c.effects[0].id == id)
        let sc = try #require(c.effects[0].parameters[ClipEffect.stageScaleKey])
        #expect(close(sc.value(atLocal: .zero), 200))
    }

    @Test func catalogKnowsTheKindButDoesNotOfferIt() {
        #expect(EffectCatalog.spec(for: ClipEffect.dynamicZoomKind) != nil)
        #expect(!EffectCatalog.all.contains { $0.kind == ClipEffect.dynamicZoomKind })
        #expect(EffectCatalog.title(for: ClipEffect.dynamicZoomKind) == "Dynamic Zoom")
    }

    // MARK: Editing the two windows

    @Test func movingKeepsTheSizeAndStaysInsidePicture() {
        let r = ZoomRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let m = r.moved(by: Vec2(0.2, -0.3))
        #expect(close(m.x, 0.3) && close(m.y, 0) && close(m.width, 0.5))
        let far = r.moved(by: Vec2(5, 5))
        #expect(close(far.x, 0.5) && close(far.y, 0.5))
    }

    @Test func cornerResizeKeepsTheOppositeCornerAndTheAspect() {
        let r = ZoomRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let a = r.resized(corner: .bottomRight, to: Vec2(0.95, 0.8))   // larger side rules
        #expect(close(a.x, 0.25) && close(a.y, 0.25) && close(a.width, 0.7) && close(a.height, 0.7))
        let b = r.resized(corner: .topLeft, to: Vec2(0.5, 0.5))        // bottom-right (0.75) stays
        #expect(close(b.x, 0.5) && close(b.y, 0.5) && close(b.width, 0.25))
        let c = r.resized(corner: .bottomRight, to: Vec2(3, 3))        // cannot leave the picture
        #expect(close(c.x, 0.25) && close(c.width, 0.75))
        let d = r.resized(corner: .bottomRight, to: Vec2(0.25, 0.25))  // collapsed: smallest window
        #expect(close(d.width, 0.01))
    }

    @Test func zoomAmountKeepsTheCentre() {
        let r = ZoomRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)      // center 0.75
        let z = r.withZoom(4)
        #expect(close(z.width, 0.25) && close(z.x + z.width / 2, 0.75) && close(z.y + z.height / 2, 0.75))
        let edge = r.withZoom(1.0)                                     // full picture: center cannot stay
        #expect(close(edge.x, 0) && close(edge.width, 1))
    }

    @Test func windowsReadBackFromTheWrittenStage() throws {
        var c = clip()
        let a = ZoomRect(x: 0.1, y: 0.2, width: 0.6, height: 0.6), b = ZoomRect(x: 0.4, y: 0.4, width: 0.5, height: 0.5)
        DynamicZoom.apply(to: &c, from: a, to: b, picture: pic, ease: .easeOut)
        let w = try #require(DynamicZoom.windows(of: c, picture: pic))
        #expect(close(w.start.x, 0.1, 1e-9) && close(w.start.y, 0.2, 1e-9) && close(w.start.width, 0.6, 1e-9))
        #expect(close(w.end.x, 0.4, 1e-9) && close(w.end.y, 0.4, 1e-9) && close(w.end.width, 0.5, 1e-9))
        #expect(w.ease == .easeOut)
        #expect(DynamicZoom.windows(of: clip(), picture: pic) == nil)
    }

    @Test func easeIsRecognisedForEveryPreset() throws {
        for e in ZoomEase.allCases {
            var c = clip()
            DynamicZoom.apply(to: &c, from: .full, to: .centred(zoom: 2), picture: pic, ease: e)
            #expect(DynamicZoom.windows(of: c, picture: pic)?.ease == e)
        }
    }
}
