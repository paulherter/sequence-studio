#if canImport(CoreText)
import Foundation
import Synchronization
import Testing
import SQCore
@testable import SQText

// G11: Follow at evaluation time measures text targets through the provider SQText installs; the box equals the one the
// Graphics overlay uses (`graphicsRect`). Playback never lays a text out on its thread (stand-in or authored, warmed in
// the background); export (`GraphicsTextBounds.exact`) always measures.

private let format = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))

private func ref(_ s: String) throws -> GeneratorRef {
    try TextGenerator.makeRef(template: TextTemplate(name: "T", text: s, style: TextStyle(fontName: "Helvetica-Bold", size: 100, color: .white)),
                              animations: nil)
}

/// A box following `text` (padding 16) in a one-clip project; returns the box request at 1 s.
private func boxRequest(text: GraphicsLayer, box: GraphicsLayer) throws -> LayerRequest {
    let v1 = Track(kind: .video)
    let tl = Timeline(name: "S", format: format, tracks: [v1])
    var p = Project(name: "P", timelines: [tl])
    _ = try p.addGraphicsClip(in: tl.id, at: .zero, track: v1.id, duration: Time(4, 1), layers: [box, text])
    return try #require(p.timeline(tl.id)!.videoLayers(at: Time(1, 1)).first { $0.clip == box.id })
}

private func follower(of text: GraphicsLayer) -> GraphicsLayer {
    var box = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    box.follow = GraphicsFollow(target: .layer(id: text.id), padding: 16)
    return box
}

private func fits(_ req: LayerRequest, _ r: GraphicsRect, offset: Vec2 = .zero) -> Bool {
    abs((req.shape?.width ?? 0) - (r.width + 32)) < 1e-6 && abs((req.shape?.height ?? 0) - (r.height + 32)) < 1e-6
        && abs(req.transform.position.x - (r.midX + offset.x)) < 1e-6 && abs(req.transform.position.y - (r.midY + offset.y)) < 1e-6
}

private func waitUntilCached(_ r: GeneratorRef) async throws {
    for _ in 0..<500 where !TextGenerator.isCached(ref: r) { try await Task.sleep(for: .milliseconds(10)) }
}

@Suite(.serialized) struct FollowMeasureTests {
    init() { TextGenerator.installFollowMeasure() }

    @Test func evaluationFollowsTheMeasuredTextBox() throws {
        TextGenerator.installFollowMeasure()      // idempotent
        #expect(GraphicsTextBounds.current != nil)
        let r0 = try ref("Lower third")
        var text = GraphicsLayer.text(r0)
        text.animation.position = AnimatedProperty(Vec2(120, -80))
        let r = try #require(TextGenerator.graphicsRect(ref: r0, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: format))
        #expect(fits(try boxRequest(text: text, box: follower(of: text)), r, offset: Vec2(120, -80)))
    }

    /// Item lanes: a 6 s Graphic, a text shown 2..<4 s with a 0.5 s slide In and Out, a box following it. The box is
    /// measured on the item's range like the picture: mid-slide at clip time 2.1 s, and on the Out that ends with the
    /// range at 3.9 s (not at rest, and not anchored to the clip's end). Export evaluation; an item without a range
    /// keeps clip time.
    @Test func aFollowerOfARangedTextIsMeasuredOnTheRange() throws {
        func slide(_ from: Double, _ to: Double) -> KeyframeTemplate {
            KeyframeTemplate(tracks: [AnimationTrack(property: "positionX", keys: [(.zero, from, .linear), (Time(1, 2), to, .linear)])],
                             duration: Time(1, 2))
        }
        let template = TextTemplate(name: "T", text: "Slide \(UUID())", style: TextStyle(fontName: "Helvetica-Bold", size: 100, color: .white))
        let r0 = try TextGenerator.makeRef(template: template, animations: AnimationSet(in: slide(-300, 0), out: slide(0, 300)))
        func request(range: TimeRange?, at t: Time) throws -> LayerRequest {
            var text = GraphicsLayer.text(r0)
            text.range = range
            let box = follower(of: text)
            let v1 = Track(kind: .video)
            let tl = Timeline(name: "S", format: format, tracks: [v1])
            var p = Project(name: "P", timelines: [tl])
            _ = try p.addGraphicsClip(in: tl.id, at: .zero, track: v1.id, duration: Time(6, 1), layers: [box, text])
            return try GraphicsTextBounds.$exact.withValue(true) {
                try #require(p.timeline(tl.id)!.videoLayers(at: t).first { $0.clip == box.id })
            }
        }
        func rect(_ local: Time, _ duration: Time) throws -> GraphicsRect {
            try #require(TextGenerator.graphicsRect(ref: r0, localTime: local, clipDuration: duration, canvas: format))
        }
        let range = TimeRange(start: Time(2, 1), end: Time(4, 1))
        for t in [Time(21, 10), Time(39, 10)] {
            let onRange = try rect(t - range.start, range.duration), onClip = try rect(t, Time(6, 1))
            #expect(abs(onRange.midX - onClip.midX) > 10)                 // the slide moves the box: the time base matters
            #expect(fits(try request(range: range, at: t), onRange))
            #expect(fits(try request(range: nil, at: t), onClip))         // unranged: unchanged
        }
    }

    @Test func uncachedTextIsNotLaidOutOnTheEvaluationPathAndRedrawsWhenWarm() async throws {
        let owner = NSObject(), told = Mutex(0)
        TextGenerator.addFollowMeasureObserver(owner) { _ in told.withLock { $0 += 1 } }
        defer { TextGenerator.removeFollowMeasureObserver(owner) }
        let cold = try ref("Cold \(UUID())")
        let text = GraphicsLayer.text(cold), box = follower(of: text)
        let layouts = TextGenerator.followSyncLayouts
        let first = try boxRequest(text: text, box: box)
        #expect(TextGenerator.followSyncLayouts == layouts)              // nothing laid out on this thread
        #expect(first.shape == box.shapeStyle(atLocal: Time(1, 1)))      // drawn as authored meanwhile
        try await waitUntilCached(cold)
        for _ in 0..<500 where told.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(told.withLock { $0 } >= 1)                               // playback is told to redraw
        let r = try #require(TextGenerator.graphicsRect(ref: cold, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: format))
        #expect(fits(try boxRequest(text: text, box: box), r))
    }

    @Test func exportMeasuresAColdTextExactly() throws {
        let cold = try ref("Export \(UUID())")
        let text = GraphicsLayer.text(cold), box = follower(of: text)
        let layouts = TextGenerator.followSyncLayouts
        let req = try GraphicsTextBounds.$exact.withValue(true) { try boxRequest(text: text, box: box) }
        #expect(TextGenerator.followSyncLayouts == layouts + 1)
        let r = try #require(TextGenerator.graphicsRect(ref: cold, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: format))
        #expect(fits(req, r))
    }

    @Test func aNewTextStandsInWithTheLayersLastBoxWhileItIsLaidOut() async throws {
        let old = try ref("Old \(UUID())")
        let text = GraphicsLayer.text(old)
        let box = follower(of: text)
        let v1 = Track(kind: .video)
        let tl = Timeline(name: "S", format: format, tracks: [v1])
        var p = Project(name: "P", timelines: [tl])
        let clip = try p.addGraphicsClip(in: tl.id, at: .zero, track: v1.id, duration: Time(4, 1), layers: [box, text])
        func request() throws -> LayerRequest { try #require(p.timeline(tl.id)!.videoLayers(at: Time(1, 1)).first { $0.clip == box.id }) }
        let rOld = try #require(TextGenerator.graphicsRect(ref: old, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: format))
        #expect(fits(try request(), rOld))
        // Typing: the layer's new text is not laid out yet; the box stays on the old text (as the picture keeps its raster).
        let new = try ref("A much longer new text \(UUID())")
        try p.editGraphics(clipID: clip) { $0.update(text.id) { $0.content = .text(ref: new) } }
        #expect(fits(try request(), rOld))
        try await waitUntilCached(new)
        let rNew = try #require(TextGenerator.graphicsRect(ref: new, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: format))
        #expect(fits(try request(), rNew))
    }

    @Test func clipsSharingLayerIdsDoNotShareTheirStandIn() async throws {
        // Two graphics clips made from one template have the same layer ids; a cold text in the second must not stand in
        // with the first clip's box.
        let old = try ref("Shared \(UUID())"), new = try ref("Another much longer text \(UUID())")
        let textA = GraphicsLayer.text(old)
        var textB = textA
        textB.content = .text(ref: new)
        let box = follower(of: textA)
        let v1 = Track(kind: .video), v2 = Track(kind: .video)
        let tl = Timeline(name: "S", format: format, tracks: [v1, v2])
        var p = Project(name: "P", timelines: [tl])
        _ = try p.addGraphicsClip(in: tl.id, at: .zero, track: v1.id, duration: Time(4, 1), layers: [box, textA])
        let b = try p.addGraphicsClip(in: tl.id, at: .zero, track: v2.id, duration: Time(4, 1), layers: [box, textB])
        let rOld = try #require(TextGenerator.graphicsRect(ref: old, localTime: Time(1, 1), clipDuration: Time(4, 1), canvas: format))
        let reqs = p.timeline(tl.id)!.videoLayers(at: Time(1, 1)).filter { $0.clip == box.id }
        #expect(reqs.count == 2)
        _ = b
        // Clip A measured the old text; clip B's cold text is drawn as authored, not at A's box.
        #expect(reqs.contains { fits($0, rOld) })
        #expect(reqs.contains { $0.shape == box.shapeStyle(atLocal: Time(1, 1)) })
        try await waitUntilCached(new)
    }

    @Test func oneInFlightTableServesEveryCaller() async throws {
        let cold = try ref("Shared warm \(UUID())")
        let told = Mutex(0)
        TextGenerator.warmInBackground(cold) { told.withLock { $0 += 1 } }
        TextGenerator.warmInBackground(cold) { told.withLock { $0 += 1 } }     // joins the same layout
        for _ in 0..<500 where told.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(told.withLock { $0 } == 2)
        #expect(TextGenerator.isCached(ref: cold))
    }

    @Test func aFailedLayoutIsRetriedAfterAReset() async throws {
        let cold = try ref("Failed once \(UUID())")
        TextGenerator.markLayoutFailed(cold)
        TextGenerator.warmInBackground(cold)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!TextGenerator.isCached(ref: cold))                  // not tried while the failure stands
        TextGenerator.resetFailedLayouts()
        #expect(!TextGenerator.layoutFailed(cold))
        TextGenerator.warmInBackground(cold)
        try await waitUntilCached(cold)
        #expect(TextGenerator.isCached(ref: cold))
    }

    @Test func resettingFailuresWakesTheObservers() {
        let owner = NSObject(), told = Mutex(0)
        TextGenerator.addFailedLayoutResetObserver(owner) { told.withLock { $0 += 1 } }
        defer { TextGenerator.removeFailedLayoutResetObserver(owner) }
        TextGenerator.resetFailedLayouts()                                   // nothing failed: nobody is woken
        #expect(told.withLock { $0 } == 0)
        TextGenerator.markLayoutFailed(GeneratorRef(kind: GeneratorRef.text, payload: Data([9])))
        TextGenerator.resetFailedLayouts()
        #expect(told.withLock { $0 } == 1)
    }
}
#endif
