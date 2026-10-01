import CoreGraphics
import Foundation
import SSCore
import SSRender
import SSText
import Testing
@testable import SSEditorUI

private func close(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }
private let seq = CGSize(width: 1920, height: 1080)

@Suite struct MonitorViewMappingTests {
    private func mapping(_ z: ViewerZoom = .fit) -> MonitorViewMapping {
        MonitorViewMapping(viewSize: CGSize(width: 960, height: 600), backingScale: 2, sequenceSize: seq, zoom: z)
    }

    @Test func fitRectIsCenteredInPoints() {
        let r = mapping().canvasRect
        #expect(abs(r.width - 960) < 1e-9)
        #expect(abs(r.height - 540) < 1)
        #expect(abs(r.midX - 480) < 1 && abs(r.midY - 300) < 1)
        #expect(abs(mapping().scale - 1000.0 / 1000.0 * 960 * 2 / 1920) < 1e-9)
    }

    @Test func panFollowsThePointer() {
        let m = mapping()
        let z = m.panned(byViewDelta: CGSize(width: 40, height: -20))
        let after = MonitorViewMapping(viewSize: m.viewSize, backingScale: 2, sequenceSize: seq, zoom: z)
        #expect(abs(after.canvasRect.midX - (m.canvasRect.midX + 40)) < 1)
        #expect(abs(after.canvasRect.midY - (m.canvasRect.midY - 20)) < 1)
    }

    @Test func zoomKeepsThePointUnderTheCursor() {
        let m = mapping()
        let p = CGPoint(x: 700, y: 150)
        let before = m.sequenceOffset(fromView: p)
        let z = m.zoomed(by: 3, about: p)
        let after = MonitorViewMapping(viewSize: m.viewSize, backingScale: 2, sequenceSize: seq, zoom: z)
        let a = after.sequenceOffset(fromView: p)
        #expect(abs(a.x - before.x) < 1.5 && abs(a.y - before.y) < 1.5)
        #expect(after.scale > m.scale * 2.9)
    }

    @Test func zoomIsClampedAndSnapsBackToFit() {
        let m = mapping()
        if case .view(let s, _, _) = m.zoomed(by: 1000, about: .zero) { #expect(s == MonitorViewMapping.maxScale) } else { Issue.record("not a free view") }
        if case .view(let s, _, _) = m.zoomed(by: 0.0001, about: .zero) { #expect(s == MonitorViewMapping.minScale) } else { Issue.record("not a free view") }
        let zoomedIn = mapping(m.zoomed(by: 2, about: CGPoint(x: 480, y: 300)))
        #expect(zoomedIn.zoom != .fit)
        #expect(zoomedIn.zoomed(by: 0.5, about: CGPoint(x: 480, y: 300)).isFit)
    }

    @Test func panCannotLoseThePicture() {
        let z = mapping().panned(byViewDelta: CGSize(width: 100_000, height: 100_000))
        if case .view(_, let cx, let cy) = z { #expect(abs(cx) <= 960 && abs(cy) <= 540) } else { Issue.record("not a free view") }
    }

    @Test func sequenceOffsetOfTheCanvasCentreIsZero() {
        #expect(mapping().sequenceOffset(fromView: CGPoint(x: 480, y: 300)) == Vec2(0, 0))
        let o = mapping().sequenceOffset(fromView: CGPoint(x: 480 + 96, y: 300 - 54))
        #expect(abs(o.x - 192) < 1.5 && abs(o.y + 108) < 1.5)
    }

    @Test func typePlacementClampsToTheCanvas() {
        let m = mapping()
        #expect(TypeToolPlacement.position(forClick: CGPoint(x: 480 + 96, y: 300), mapping: m).map { abs($0.x - 192) < 1.5 } == true)
        let far = TypeToolPlacement.position(forClick: CGPoint(x: 5000, y: -5000), mapping: m)
        #expect(far == Vec2(960, -540))
        // Outside the canvas but inside the view (zoomed out letterbox): no text box.
        let small = MonitorViewMapping(viewSize: CGSize(width: 960, height: 600), backingScale: 2, sequenceSize: seq, zoom: .percent(50))
        #expect(TypeToolPlacement.position(forClick: CGPoint(x: 2, y: 2), mapping: small) == nil)
    }

    @Test func typeDragMakesABoxAndAShortDragIsAClick() {
        let m = mapping()
        let a = CGPoint(x: 480, y: 300), b = CGPoint(x: 480 + 96, y: 300 + 54)
        let (centre, box) = TypeToolPlacement.box(from: a, to: b, mapping: m, minDrag: 6)!
        #expect(abs(box.width - 192) < 1.5 && abs(box.height - 108) < 1.5)
        #expect(abs(centre.x - 96) < 1.5 && abs(centre.y - 54) < 1.5)
        // Dragging the other way gives the same box.
        let back = TypeToolPlacement.box(from: b, to: a, mapping: m, minDrag: 6)!
        #expect(back.1 == box)
        #expect(TypeToolPlacement.box(from: a, to: CGPoint(x: 483, y: 303), mapping: m, minDrag: 6) == nil)
        // A drag running past the canvas edge is clipped to the canvas.
        let big = TypeToolPlacement.box(from: a, to: CGPoint(x: 9000, y: 9000), mapping: m, minDrag: 6)!
        #expect(abs(big.1.width - 960) < 1.5 && abs(big.1.height - 540) < 1.5)
    }
}

@Suite struct SnapGuidesTests {
    let canvas = CGSize(width: 1920, height: 1080)

    @Test func targetsHoldCanvasAndOtherLayers() {
        let t = SnapGuides.targets(canvas: canvas, others: [CGRect(x: 100, y: 50, width: 200, height: 100)])
        #expect(t.xs.contains(0) && t.xs.contains(-960) && t.xs.contains(960) && t.xs.contains(100) && t.xs.contains(200) && t.xs.contains(300))
        #expect(t.ys.contains(0) && t.ys.contains(-540) && t.ys.contains(540) && t.ys.contains(50) && t.ys.contains(100) && t.ys.contains(150))
    }

    @Test func centreSnapsWithinThreshold() {
        let t = SnapGuides.targets(canvas: canvas, others: [])
        let box = CGRect(x: -100 + 5, y: -50 - 3, width: 200, height: 100)       // centre (5, -3)
        let r = SnapGuides.snap(box: box, targets: t, threshold: 8)
        #expect(abs(r.dx + 5) < 1e-9 && abs(r.dy - 3) < 1e-9)
        #expect(r.verticalLines == [0] && r.horizontalLines == [0])
    }

    @Test func nothingSnapsBeyondTheThreshold() {
        let t = SnapGuides.targets(canvas: canvas, others: [])
        let r = SnapGuides.snap(box: CGRect(x: 200, y: 200, width: 100, height: 100), targets: t, threshold: 8)
        #expect(r.dx == 0 && r.dy == 0 && r.verticalLines.isEmpty && r.horizontalLines.isEmpty)
    }

    @Test func edgeSnapsToCanvasEdgeAndOtherLayer() {
        let t = SnapGuides.targets(canvas: canvas, others: [CGRect(x: 300, y: -400, width: 100, height: 100)])
        let left = SnapGuides.snap(box: CGRect(x: -957, y: 0, width: 100, height: 100), targets: t, threshold: 8)
        #expect(abs(left.dx + 3) < 1e-9 && left.verticalLines == [-960])
        let other = SnapGuides.snap(box: CGRect(x: 100 + 3, y: 0, width: 197, height: 100), targets: t, threshold: 8)   // right edge 300 vs others' minX 300
        #expect(other.verticalLines.contains(300))
    }

    @Test func nearestTargetWins() {
        let t = SnapGuides.Targets(xs: [0, 4], ys: [])
        let r = SnapGuides.snap(box: CGRect(x: 2.5, y: 0, width: 0, height: 0), targets: t, threshold: 8)
        #expect(abs(r.dx - 1.5) < 1e-9)
    }

    @Test func layerBoundsFollowScaleAndRotation() {
        let b = LayerBounds.rect(size: CGSize(width: 400, height: 200), transform: ClipTransform(position: Vec2(10, 20), scale: Vec2(0.5, 0.5)))
        #expect(b == CGRect(x: -90, y: -30, width: 200, height: 100))
        let r = LayerBounds.rect(size: CGSize(width: 400, height: 200), transform: ClipTransform(rotation: 90))
        #expect(abs(r.width - 200) < 1e-9 && abs(r.height - 400) < 1e-9)
        let a = LayerBounds.rect(size: CGSize(width: 400, height: 200), transform: ClipTransform(anchor: Vec2(-200, -100)))
        #expect(a == CGRect(x: 0, y: 0, width: 400, height: 200))   // anchor at the top-left corner sits at position
    }
}

@Suite struct NativeSizeOverlayTests {
    /// 4K clip in a 1080p sequence at the frame-fit scale 50 %: the quad fills the canvas (native-pixel geometry).
    private func geo(_ t: ClipTransform) -> TransformOverlayGeometry {
        TransformOverlayGeometry(sequenceSize: seq, viewRect: CGRect(x: 0, y: 0, width: 960, height: 540), mediaAspect: 16.0 / 9,
                                 transform: t, mediaPixelSize: CGSize(width: 3840, height: 2160))
    }

    @Test func quadUsesNativePixelsTimesScale() {
        let q = geo(ClipTransform(scale: Vec2(0.5, 0.5))).quad
        #expect(close(q[0], CGPoint(x: 0, y: 0)) && close(q[2], CGPoint(x: 960, y: 540)))
        let big = geo(ClipTransform(scale: Vec2(1, 1))).quad
        #expect(close(big[0], CGPoint(x: -480, y: -270)))
    }

    @Test func cornerScaleWritesSourcePixelScale() {
        let g = geo(ClipTransform(scale: Vec2(0.5, 0.5)))
        // Drag the bottom-right corner (960,540) outwards by the half canvas: picture doubles -> scale 1.0.
        let t = g.scaled(handle: .bottomRight, from: CGPoint(x: 960, y: 540), to: CGPoint(x: 1440, y: 810))
        #expect(abs(t.scale.x - 1) < 1e-6 && abs(t.scale.y - 1) < 1e-6)
    }

    @Test func anchorDragKeepsThePictureInPlace() {
        let g = geo(ClipTransform(scale: Vec2(0.5, 0.5)))
        let t = g.anchorMoved(from: CGPoint(x: 480, y: 270), to: CGPoint(x: 580, y: 270))
        let moved = TransformOverlayGeometry(sequenceSize: seq, viewRect: g.viewRect, mediaAspect: 16.0 / 9, transform: t,
                                             mediaPixelSize: CGSize(width: 3840, height: 2160))
        for (a, b) in zip(g.quad, moved.quad) { #expect(close(a, b)) }
        // 100 view px = 200 sequence px = 400 native px at scale 0.5.
        #expect(abs(t.anchor.x - 400) < 1e-6)
    }
}

@Suite struct OverlayTargetTests {
    private func project(with clip: Clip, media: MediaRef? = nil) -> (Project, Timeline) {
        var p = Project(name: "t")
        if let media { p.media.append(media) }
        let tl = Timeline(name: "s", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                          tracks: [Track(kind: .video, clips: [clip])])
        p.timelines = [tl]
        return (p, tl)
    }

    @Test func textTargetUsesTheRasterSizeAndShift() throws {
        let style = TextStyle(fontName: "Helvetica-Bold", size: 100, color: .white)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "Hello", style: style), animations: nil)
        let id = UUID()
        var clip = Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)),
                        start: .zero, generator: ref)
        clip.animation.position = AnimatedProperty(Vec2(30, 40))
        let (p, tl) = project(with: clip)
        let target = try #require(OverlayTarget.make(clip: clip, project: p, timeline: tl, at: Time(1, 1)))
        #expect(target.isText && target.size.width > 50 && target.size.height > 50)
        // Display position = base position + the raster centre relative to the canvas centre; round-trips back.
        let back = target.baseTransform(fromDisplay: target.displayTransform)
        #expect(abs(back.position.x - 30) < 1e-9 && abs(back.position.y - 40) < 1e-9)
    }

    @Test func pictureTargetUsesUprightMediaSize() throws {
        let v = VideoTrackInfo(width: 3840, height: 2160, codec: "hvc1", bitDepth: 10, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let m = MediaRef(name: "m", path: "/x.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1),
                         info: MediaInfo(duration: Time(10, 1), video: v))
        let clip = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let (p, tl) = project(with: clip, media: m)
        let target = try #require(OverlayTarget.make(clip: clip, project: p, timeline: tl, at: .zero))
        #expect(!target.isText && target.size == CGSize(width: 3840, height: 2160))
        #expect(target.displayTransform == clip.transform(at: .zero))
    }

    @Test func clipOutsideThePlayheadHasNoTarget() throws {
        let m = MediaRef(name: "m", path: "/x.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(10, 1), info: nil)
        let clip = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let (p, tl) = project(with: clip, media: m)
        #expect(OverlayTarget.make(clip: clip, project: p, timeline: tl, at: Time(6, 1)) == nil)
    }
}
