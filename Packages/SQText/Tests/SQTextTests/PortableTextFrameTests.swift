#if canImport(CoreText)
import CoreVideo
import Foundation
import Testing
import SQCore
@testable import SQText

/// `TextGenerator.portableFrame` (Windows titles) places the raster and folds the animation like `TextGenerator.frame`.
@Suite struct PortableTextFrameTests {
    private let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))

    @Test func placementAndAnimationMatchTheCoreTextFrame() throws {
        let fade = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)])],
                                    duration: Time(1, 5), anchor: .start)
        var style = TextStyle(size: 90, color: .white)
        style.alignment = .left
        let template = TextTemplate(name: "t", text: "Hello\nWorld", style: style, box: TextBox(width: 900, height: 500))
        let ref = try TextGenerator.makeRef(template: template, animations: AnimationSet(in: fade, out: nil))
        for t in [Time.zero, Time(1, 10), Time(1, 1)] {
            let mac = try #require(try TextGenerator.frame(ref: ref, localTime: t, clipDuration: Time(3, 1), canvas: canvas, scale: 1))
            let win = try #require(try TextGenerator.portableFrame(ref: ref, localTime: t, clipDuration: Time(3, 1), canvas: canvas))
            #expect(win.picture.width == CVPixelBufferGetWidth(mac.buffer))
            #expect(win.picture.height == CVPixelBufferGetHeight(mac.buffer))
            var base = ClipTransform.identity
            base.position = Vec2(12, -30); base.scale = Vec2(1.5, 1.5); base.opacity = 0.8
            let a = mac.layerTransform(base: base, canvas: canvas), b = win.layerTransform(base: base, canvas: canvas)
            #expect(abs(a.position.x - b.position.x) < 1e-9 && abs(a.position.y - b.position.y) < 1e-9)
            #expect(a.scale == b.scale && a.rotation == b.rotation && abs(a.opacity - b.opacity) < 1e-12)
            #expect(a.anchor == b.anchor)
            // A cached raster only samples the animation again.
            let first = try #require(try TextGenerator.portableFrame(ref: ref, localTime: .zero, clipDuration: Time(3, 1), canvas: canvas))
            let reused = try #require(try TextGenerator.portableFrame(ref: ref, localTime: t, clipDuration: Time(3, 1), canvas: canvas,
                                                                      raster: first))
            let c = reused.layerTransform(base: base, canvas: canvas)
            #expect(c.position == b.position && c.opacity == b.opacity && reused.picture.pixels == win.picture.pixels)
        }
    }

    @Test func emptyTextHasNoFrameAndTheFootageFillComesAlong() throws {
        var style = TextStyle(size: 80)
        let empty = try TextGenerator.makeRef(template: TextTemplate(name: "e", text: "", style: style), animations: nil)
        #expect(try TextGenerator.portableFrame(ref: empty, localTime: .zero, clipDuration: Time(1, 1), canvas: canvas) == nil)
        style.footageFill = .stencil
        let filled = try TextGenerator.makeRef(template: TextTemplate(name: "f", text: "Fill", style: style), animations: nil)
        let f = try #require(try TextGenerator.portableFrame(ref: filled, localTime: .zero, clipDuration: Time(1, 1), canvas: canvas))
        #expect(f.footageFill == .stencil)
    }
}
#endif
