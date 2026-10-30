#if canImport(CoreText)
import CoreVideo
import Foundation
import Testing
import SQCore
@testable import SQText

/// Text animators on the portable raster (Windows) against the Core Text animated raster: same size and origin, nearly
/// the same coverage, for in-between states of every kind (fade, pop about the unit, slide, blur).
@Suite struct PortableAnimatedTextTests {
    private let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))

    private func states(_ text: String, _ style: TextStyle, _ animator: TextAnimator, at t: Time) throws -> [TextCharacterState] {
        let layout = TextLayout.layout(text: text, style: style.drawn, maxWidth: nil)
        let set = AnimationSet(in: KeyframeTemplate(textAnimator: animator), out: nil)
        return try #require(set.characterStates(units: TextUnits.segment(layout), clipTime: t, clipDuration: Time(10, 1)))
    }

    private func compare(_ text: String, _ style: TextStyle, _ animator: TextAnimator, at t: Time,
                         highlight: TextHighlight? = nil, meanBound: Float = 0.03) throws {
        let st = try states(text, style, animator, at: t)
        #expect(st.contains { !$0.isRest })
        let mac = try #require(try TextRenderer.render(text: text, style: style, maxWidth: nil, highlight: highlight, characterStates: st))
        let pc = try #require(PortableTextRenderer.render(text: text, style: style, maxWidth: nil, highlight: highlight,
                                                          characterStates: st))
        #expect(pc.picture.width == mac.pixelWidth && pc.picture.height == mac.pixelHeight)
        #expect(abs(pc.originX - mac.originX) < 1e-9 && abs(pc.originY - mac.originY) < 1e-9)
        let pb = mac.linearBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!, rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let w = min(pc.picture.width, mac.pixelWidth), h = min(pc.picture.height, mac.pixelHeight)
        var diff: Float = 0, macInk: Float = 0, pcInk: Float = 0
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<w {
                for k in 0..<4 {
                    let a = Float(row[x * 4 + k]), b = pc.picture.pixels[(y * pc.picture.width + x) * 4 + k]
                    diff += abs(a - b)
                    if k == 3 { macInk += a; pcInk += b }
                }
            }
        }
        // The static raster's bounds (PortableTextRasterTests): glyph runs drift up to 0.2 px from CTLineDraw.
        let mean = diff / Float(max(1, w * h * 4))
        #expect(mean < meanBound, "mean difference \(mean)")
        #expect(abs(pcInk - macInk) <= macInk * 0.06, "coverage \(pcInk) vs \(macInk)")
    }

    @Test func restStatesDrawTheStaticRaster() throws {
        let style = TextStyle(size: 64)
        let st = try states("Hi you", style, TextAnimator(effect: .fade, unit: .word, duration: Time(1, 5), stagger: Time(1, 10)),
                            at: Time(5, 1))
        #expect(!st.contains { !$0.isRest })
        let a = try #require(PortableTextRenderer.render(text: "Hi you", style: style, maxWidth: nil, characterStates: st))
        let b = try #require(PortableTextRenderer.render(text: "Hi you", style: style, maxWidth: nil))
        #expect(a.picture.width == b.picture.width && a.picture.height == b.picture.height)
        #expect(a.originX == b.originX && a.originY == b.originY)
        let d = zip(a.picture.pixels, b.picture.pixels).map { abs($0 - $1) }.max() ?? 0
        #expect(d < 1e-4, "max difference \(d)")
    }

    @Test func fadeByCharacterWithStroke() throws {
        var style = TextStyle(size: 64, stroke: TextStroke(color: RGBAColor(red: 1, green: 0, blue: 0), width: 3))
        style.underline = true
        try compare("Hello", style, TextAnimator(effect: .fade, unit: .character, easing: .linear, duration: Time(1, 2),
                                                 stagger: Time(1, 10)), at: Time(3, 10))
    }

    @Test func popAboutTheWordGrowsNothingPastTheMac() throws {
        try compare("Pop it", TextStyle(size: 64), TextAnimator(effect: .pop, unit: .word, easing: .linear, duration: Time(1, 2),
                                                                stagger: Time(1, 5)), at: Time(3, 10))
    }

    @Test func slideMovesTheRasterBounds() throws {
        try compare("Slide", TextStyle(size: 64, shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.7),
                                                                   offsetX: 3, offsetY: 3, blur: 4)),
                    TextAnimator(effect: .slide, unit: .line, easing: .linear, duration: Time(1, 1), stagger: .zero, distance: 60),
                    at: Time(1, 2))
    }

    @Test func blurInSoftensTheCharacters() throws {
        try compare("Blur", TextStyle(size: 64), TextAnimator(effect: .blur, unit: .character, easing: .linear,
                                                              duration: Time(1, 1), stagger: Time(1, 10), blurRadius: 8),
                    at: Time(1, 2), meanBound: 0.04)
    }

    @Test func karaokeColorsSurviveTheAnimation() throws {
        let style = TextStyle(size: 56, color: .white)
        try compare("one two", style, TextAnimator(effect: .fade, unit: .word, easing: .linear, duration: Time(1, 1),
                                                   stagger: Time(1, 2)), at: Time(1, 2),
                    highlight: TextHighlight(words: 1..<2, color: RGBAColor(red: 1, green: 0.8, blue: 0)))
    }

    /// `portableFrame` draws the animated picture while the animator runs, at the Mac frame's size and place, and keeps
    /// the resting picture once every character is at rest.
    @Test func portableFrameFollowsTheAnimator() throws {
        let animator = TextAnimator(effect: .slide, unit: .word, easing: .linear, duration: Time(1, 2), stagger: Time(1, 5))
        let template = TextTemplate(name: "t", text: "Move along", style: TextStyle(size: 72))
        let ref = try TextGenerator.makeRef(template: template,
                                            animations: AnimationSet(in: KeyframeTemplate(textAnimator: animator), out: nil))
        let mid = Time(1, 4), dur = Time(5, 1)
        let mac = try #require(try TextGenerator.frame(ref: ref, localTime: mid, clipDuration: dur, canvas: canvas, scale: 1))
        let win = try #require(try TextGenerator.portableFrame(ref: ref, localTime: mid, clipDuration: dur, canvas: canvas))
        #expect(win.characterStates != nil)
        #expect(win.picture.width == CVPixelBufferGetWidth(mac.buffer) && win.picture.height == CVPixelBufferGetHeight(mac.buffer))
        let a = mac.layerTransform(base: .identity, canvas: canvas), b = win.layerTransform(base: .identity, canvas: canvas)
        #expect(abs(a.position.x - b.position.x) < 1e-9 && abs(a.position.y - b.position.y) < 1e-9)
        let a2 = mac.layerTransform(base: .identity, canvas: canvas, pivotAtText: true)
        let b2 = win.layerTransform(base: .identity, canvas: canvas, pivotAtText: true)
        #expect(abs(a2.anchor.x - b2.anchor.x) < 1e-9 && abs(a2.anchor.y - b2.anchor.y) < 1e-9)
        // Next frame of the animation: a new picture; at rest the resting one, kept from then on.
        let next = try #require(try TextGenerator.portableFrame(ref: ref, localTime: mid + Time(1, 30), clipDuration: dur,
                                                                canvas: canvas, raster: win))
        #expect(!next.sharesPicture(with: win))
        let rest = try #require(try TextGenerator.portableFrame(ref: ref, localTime: Time(2, 1), clipDuration: dur, canvas: canvas,
                                                                raster: next))
        #expect(rest.characterStates == nil)
        let later = try #require(try TextGenerator.portableFrame(ref: ref, localTime: Time(3, 1), clipDuration: dur, canvas: canvas,
                                                                 raster: rest))
        #expect(later.sharesPicture(with: rest) && later.picture.pixels == rest.picture.pixels)
    }
}
#endif
