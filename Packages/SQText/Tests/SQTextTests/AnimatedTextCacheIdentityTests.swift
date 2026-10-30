#if canImport(CoreText)
import Testing
import Foundation
import CoreVideo
import CoreText
import Synchronization
import SQCore
@testable import SQText

// The playback shortcuts for animated text (ENGINE-NOTES "Animated captions") must not change the picture: the tight
// raster of an in-between frame is the same pixels as that part of the full raster, the frame the cache hands out is
// placed where the full one is, and the memos return what the unmemoized code returns.

/// The linear half-float pixels of a raster (RGBA, premultiplied).
private struct LinearPixels {
    let w: Int, h: Int
    /// Raw half-float bit patterns: comparing bits first keeps the debug-build cost low (the float conversion per sample
    /// made the script-font cases take ~40 s each, so the suite stayed silent past the 300 s test watchdog).
    let bits: [UInt16]
    func at(_ i: Int) -> Float { Float(Float16(bitPattern: bits[i])) }
    /// Says where the first pixel outside the part is (when a case fails).
    nonisolated(unsafe) static var verbose = false
    init(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var out = [UInt16](repeating: 0, count: w * h * 4)
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            out.withUnsafeMutableBytes { dst in
                for y in 0..<h { memcpy(dst.baseAddress! + y * w * 8, base + y * row, w * 8) }
            }
        }
        self.w = w; self.h = h; bits = out
    }

    /// Largest channel difference between `part` placed at (dx, dy) and this picture there, and the largest value this
    /// picture has outside it.
    func difference(to part: LinearPixels, dx: Int, dy: Int) -> (inside: Float, outside: Float) {
        var inside: Float = 0, outside: Float = 0
        bits.withUnsafeBufferPointer { b in
            part.bits.withUnsafeBufferPointer { a in
                for y in 0..<h {
                    let inRow = y >= dy && y < dy + part.h
                    for x in 0..<w {
                        let i = (y * w + x) * 4
                        if inRow, x >= dx, x < dx + part.w {
                            let j = ((y - dy) * part.w + (x - dx)) * 4
                            for c in 0..<4 where b[i + c] != a[j + c] {
                                inside = max(inside, abs(Float(Float16(bitPattern: b[i + c])) - Float(Float16(bitPattern: a[j + c]))))
                            }
                        } else if b[i] != 0 || b[i + 1] != 0 || b[i + 2] != 0 || b[i + 3] != 0 {
                            for c in 0..<4 { outside = max(outside, abs(Float(Float16(bitPattern: b[i + c])))) }
                            if Self.verbose { print("outside at \(x),\(y) (part \(dx),\(dy) \(part.w)x\(part.h) of \(w)x\(h))"); return }
                        }
                    }
                }
            }
        }
        return (inside, outside)
    }
}

/// Largest channel difference between `tight` and the same region of `full`, and the largest value `full` has outside
/// that region. Nil when the tight raster does not sit on the full raster's pixel grid.
private func compare(tight: TextRaster, full: TextRaster) -> (inside: Float, outside: Float, saved: Double)? {
    let fx = (tight.originX - full.originX) * full.scale, fy = (tight.originY - full.originY) * full.scale
    guard abs(fx - fx.rounded()) < 1e-6, abs(fy - fy.rounded()) < 1e-6 else { return nil }
    let dx = Int(fx.rounded()), dy = Int(fy.rounded())
    let a = LinearPixels(tight.linearBuffer), b = LinearPixels(full.linearBuffer)
    guard dx >= 0, dy >= 0, dx + a.w <= b.w, dy + a.h <= b.h else { return nil }
    let d = b.difference(to: a, dx: dx, dy: dy)
    return (d.inside, d.outside, 1 - Double(a.w * a.h) / Double(b.w * b.h))
}

@Suite(.serialized) struct AnimatedTextCacheIdentityTests {
    static let plain = TextStyle(fontName: "Helvetica-Bold", size: 90, color: .white)
    static let dressed = TextStyle(fontName: "Helvetica-Bold", size: 90, color: .white,
                                   stroke: TextStroke(color: .black, width: 10),
                                   shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.8), offsetX: 14,
                                                      offsetY: 22, blur: 30))
    static let pill = TextStyle(fontName: "Helvetica", size: 40, color: .white,
                                background: TextBackground(color: RGBAColor(red: 0.1, green: 0.2, blue: 0.9),
                                                           padding: BoxPadding(horizontal: 24, vertical: 12), cornerRadius: 16),
                                italic: true)
    /// Bit for bit: the tight raster is the same drawing at the same device coordinates, clipped.
    static let tolerance: Float = 0

    static func animator(_ effect: TextAnimatorEffect, _ unit: TextAnimatorUnit) -> AnimationSet {
        AnimationSet(in: KeyframeTemplate(textAnimator: TextAnimator(effect: effect, unit: unit, easing: .linear,
                                                                     duration: Time(1, 2), stagger: Time(1, 10), distance: 70,
                                                                     direction: .up, blurRadius: 40)), out: nil)
    }

    /// Script fonts whose glyphs reach far past their advance box and line height (swashes, long descenders).
    static let scripts: [TextStyle] = [
        TextStyle(fontName: "Zapfino", size: 90, color: .white),
        TextStyle(fontName: "Zapfino", size: 70, color: .white, stroke: TextStroke(color: .black, width: 8),
                  shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.8), offsetX: -18, offsetY: 12, blur: 24)),
        TextStyle(fontName: "SnellRoundhand-Bold", size: 110, color: .white, italic: true),
        TextStyle(fontName: "SavoyeLetPlain", size: 120, color: .white, alignment: .left),
    ]

    /// Every effect, per unit, in three styles and a caption-like box: the tight raster equals the full one.
    @Test(arguments: [TextAnimatorEffect.fade, .pop, .slide, .typewriter, .blur])
    func tightRasterIsThePaintedPartOfTheFullRaster(_ effect: TextAnimatorEffect) throws {
        try tightEqualsFull(effect, text: "Words jump\nin here", styles: [Self.plain, Self.dressed, Self.pill])
    }

    /// The same with script fonts: the tight raster is cut from the glyphs' real outlines, so no swash is clipped (the
    /// full raster paints nothing outside it).
    @Test(arguments: [TextAnimatorEffect.fade, .pop, .slide, .typewriter, .blur])
    func tightRasterKeepsTheSwashesOfScriptFonts(_ effect: TextAnimatorEffect) throws {
        for style in Self.scripts {
            let found = CTFontCopyPostScriptName(CTFontCreateWithName(style.fontName as CFString, 10, nil)) as String
            #expect(found == style.fontName, "\(style.fontName) is not installed: the case would test the fallback font")
        }
        try tightEqualsFull(effect, text: "fly Quiz, jiffy\nglyphs & Why", styles: Self.scripts, units: [.character, .line],
                            times: [Time(3, 10)], scales: [1])
    }


    private func tightEqualsFull(_ effect: TextAnimatorEffect, text: String, styles: [TextStyle],
                                 units: [TextAnimatorUnit] = [.character, .word, .line],
                                 times: [Time] = [Time(1, 10), Time(4, 10)], scales: [Double] = [1, 0.5]) throws {
        var worstInside: Float = 0, worstOutside: Float = 0, saved = 0.0, cases = 0
        for unit in units {
            for style in styles {
                for box in [nil, TextBox(width: 900, height: 700)] as [TextBox?] {
                    let layout = TextLayout.layout(text: text, style: style, maxWidth: box?.width, boxHeight: box?.height)
                    let set = Self.animator(effect, unit)
                    for t in times {
                        guard let states = set.characterStates(units: TextUnits.segment(layout), clipTime: t, clipDuration: Time(10, 1)),
                              states.contains(where: { !$0.isRest }) else { continue }
                        for scale in (box == nil ? [1.0] : scales) {
                            let full = try #require(try TextRenderer.render(text: text, style: style, maxWidth: box?.width,
                                                                            boxHeight: box?.height, scale: scale, characterStates: states))
                            let tight = try #require(try TextRenderer.render(text: text, style: style, maxWidth: box?.width,
                                                                             boxHeight: box?.height, scale: scale, characterStates: states,
                                                                             tight: true))
                            let c = try #require(compare(tight: tight, full: full), "tight raster off the pixel grid")
                            worstInside = max(worstInside, c.inside); worstOutside = max(worstOutside, c.outside)
                            if box != nil { saved += c.saved; cases += 1 }
                        }
                    }
                }
            }
        }
        #expect(cases > 0)
        #expect(worstInside <= Self.tolerance, "\(effect): tight differs from full by \(worstInside)")
        #expect(worstOutside <= Self.tolerance, "\(effect): full raster paints \(worstOutside) outside the tight one")
        print("tight animator raster \(effect): max difference \(worstInside), outside \(worstOutside), "
            + "boxed rasters \(Int((saved / Double(max(1, cases)) * 100).rounded())) % smaller")
    }

    /// A caption that hands over is drawn at its end state (clip time == clip duration) under the next one; when its
    /// animator is not at rest there, that frame is rastered ahead only when asked for (`includingEnd`).
    @Test func theEndStateIsWarmedOnlyWhenAskedFor() async throws {
        let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        let template = TextTemplate(name: "t", text: "end state\nframe", style: Self.dressed, box: TextBox(width: 900, height: 600))
        let ref = try TextGenerator.makeRef(template: template, animations: Self.animator(.fade, .word))
        let clip = Time(3, 10)     // shorter than the animation (three words: 0.7 s)
        TextGenerator.clearCache()
        _ = try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(10, 1), canvas: canvas, scale: 1)   // static raster
        // Counted per asker (`RasterTally.ahead`), not from the process-wide stats: other tests raster in parallel.
        let asked = TextGenerator.RasterTally()
        TextGenerator.$rasterTally.withValue(asked) {
            TextGenerator.warmAnimatedInBackground(ref: ref, from: clip, step: canvas.frameDuration, clipDuration: clip)
        }
        #expect(await asked.drained())
        #expect(asked.ahead == 0)
        TextGenerator.$rasterTally.withValue(asked) {
            TextGenerator.warmAnimatedInBackground(ref: ref, from: clip, step: canvas.frameDuration, clipDuration: clip, includingEnd: true)
        }
        #expect(await asked.drained())
        #expect(asked.ahead == 1)

        // The wait budget of a tick runs on a monotonic clock and is used up after its limit.
        let long = TextGenerator.RasterWait(limit: 5)   // generous: a descheduled test thread does not use it up
        #expect(long.remaining > 0 && long.remaining <= 5)
        let budget = TextGenerator.RasterWait(limit: 0.02)
        #expect(budget.remaining <= 0.02)
        usleep(25_000)
        #expect(budget.remaining <= 0)
        #expect(TextGenerator.RasterWait(limit: -1).remaining <= 0)
        let tally = TextGenerator.RasterTally()
        try TextGenerator.$rasterTally.withValue(tally) {
            _ = try TextGenerator.frame(ref: ref, localTime: clip, clipDuration: clip, canvas: canvas, scale: 1, cropped: true)
        }
        #expect(tally.drawn == 0 && tally.waited == 0)
    }

    /// The frame the generator hands out (static cache, in-between frames rastered ahead in the background) shows the
    /// same pixels at the same place as an uncached full render of that time.
    @Test(arguments: [TextAnimatorEffect.fade, .pop, .slide, .typewriter, .blur])
    func cachedFrameMatchesTheUncachedRender(_ effect: TextAnimatorEffect) async throws {
        let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        let template = TextTemplate(name: "t", text: "cached \(effect)\nframe", style: Self.dressed, box: TextBox(width: 900, height: 600))
        let set = Self.animator(effect, .word)
        let ref = try TextGenerator.makeRef(template: template, animations: set)
        let clip = Time(10, 1), step = canvas.frameDuration
        _ = try TextGenerator.frame(ref: ref, localTime: Time(5, 1), clipDuration: clip, canvas: canvas, scale: 1)   // static raster
        // Waits for its own rasters (`RasterTally`), not for a process-wide count.
        let asked = TextGenerator.RasterTally()
        TextGenerator.$rasterTally.withValue(asked) {
            TextGenerator.warmAnimatedInBackground(ref: ref, from: step, step: step, count: 6, clipDuration: clip)
        }
        #expect(await asked.drained())
        #expect(TextGenerator.animatedCacheBytes > 0)
        let layout = TextLayout.layout(text: template.text, style: template.style, maxWidth: 900, boxHeight: 600)
        for k in 1...6 {
            let t = step * Int64(k)
            let states = try #require(set.characterStates(units: TextUnits.segment(layout), clipTime: t, clipDuration: clip))
            // Every character at rest is the static raster (as before the cache existed).
            let full = try #require(states.allSatisfy { $0.isRest }
                ? try TextRenderer.render(text: template.text, style: template.style, maxWidth: 900, boxHeight: 600)
                : try TextRenderer.render(text: template.text, style: template.style, maxWidth: 900, boxHeight: 600,
                                          characterStates: states))
            let f = try #require(try TextGenerator.frame(ref: ref, localTime: t, clipDuration: clip, canvas: canvas, scale: 1,
                                                         cropped: true))
            // Where the full raster would be placed.
            let b = full.layout.bounds
            let fullX = (Double(canvas.width) - b.width) / 2 + (full.originX - b.x)
            let fullY = (Double(canvas.height) - b.height) / 2 + (full.originY - b.y)
            let dx = Int((f.x - fullX).rounded()), dy = Int((f.y - fullY).rounded())
            #expect(abs(f.x - fullX - Double(dx)) < 1e-6 && abs(f.y - fullY - Double(dy)) < 1e-6)
            let a = LinearPixels(f.buffer), whole = LinearPixels(full.linearBuffer)
            #expect(dx >= 0 && dy >= 0 && dx + a.w <= whole.w && dy + a.h <= whole.h)
            guard dx >= 0, dy >= 0, dx + a.w <= whole.w, dy + a.h <= whole.h else { continue }
            let d = whole.difference(to: a, dx: dx, dy: dy)
            let worst = max(d.inside, d.outside)
            #expect(worst <= Self.tolerance, "\(effect) frame \(k): \(worst)")
            // The pivot (text center) stays where it is on the canvas, whatever the raster covers.
            let pf = CaptionLayout.pivot(of: full)
            let fullCentre = (x: fullX + Double(full.pixelWidth) / 2 + pf.x, y: fullY + Double(full.pixelHeight) / 2 + pf.y)
            #expect(abs(f.x + f.width / 2 + f.pivotX - fullCentre.x) < 1e-6)
            #expect(abs(f.y + f.height / 2 + f.pivotY - fullCentre.y) < 1e-6)
            // The whole rectangle is the full raster's, whatever the crop.
            #expect(abs(f.wholeX - fullX) < 1e-9 && abs(f.wholeY - fullY) < 1e-9)
            #expect(f.wholeWidth == Double(full.pixelWidth) && f.wholeHeight == Double(full.pixelHeight))
            // Without `cropped` (text clips) the frame is the whole raster, as before the cache existed.
            let u = try #require(try TextGenerator.frame(ref: ref, localTime: t, clipDuration: clip, canvas: canvas, scale: 1))
            #expect(u.x == fullX && u.y == fullY && u.width == Double(full.pixelWidth) && u.height == Double(full.pixelHeight))
            #expect(u.wholeX == u.x && u.wholeY == u.y && u.wholeWidth == u.width && u.wholeHeight == u.height)
            // A cropped frame drawn as the whole one (`RenderLayer.contentPart`): the buffer's place in the whole raster
            // in texels, and a transform equal to the whole-box frame's to the bit.
            #expect(f.partX == dx && f.partY == dy && f.wholePixelWidth == full.pixelWidth && f.wholePixelHeight == full.pixelHeight)
            #expect(!u.isPart && u.partX == 0 && u.partY == 0)
            var base = ClipTransform.identity
            base.position = Vec2(23.5, -11.25); base.anchor = Vec2(14, -6); base.scale = Vec2(1.3, 0.85); base.rotation = 19
            #expect(f.layerTransform(base: base, canvas: canvas, whole: true) == u.layerTransform(base: base, canvas: canvas))
            // Captions pivot at the text: the same holds there.
            #expect(f.wholePivotX == u.pivotX && f.wholePivotY == u.pivotY && u.wholePivotX == u.pivotX && u.wholePivotY == u.pivotY)
            #expect(f.layerTransform(base: base, canvas: canvas, pivotAtText: true, whole: true)
                    == u.layerTransform(base: base, canvas: canvas, pivotAtText: true))
        }
    }

    /// The compositor's placement of a layer (`compositeVertex`: scale and rotation about the layer center moved by the
    /// anchor), sampled per canvas pixel center with the nearest raster pixel.
    private static func composite(_ f: TextFrame, _ tr: ClipTransform, canvas: SequenceFormat) -> [Float] {
        let px = LinearPixels(f.buffer)
        let cw = canvas.width, ch = canvas.height
        var out = [Float](repeating: 0, count: cw * ch * 4)
        let a = tr.rotation * .pi / 180, cs = cos(a), sn = sin(a)
        for cy in 0..<ch {
            for cx in 0..<cw {
                let dx = Double(cx) + 0.5 - Double(cw) / 2 - tr.position.x, dy = Double(cy) + 0.5 - Double(ch) / 2 - tr.position.y
                let ux = (dx * cs + dy * sn) / tr.scale.x + tr.anchor.x + f.width / 2
                let uy = (-dx * sn + dy * cs) / tr.scale.y + tr.anchor.y + f.height / 2
                // A hair off the pixel edge so both rasters round the same way at an exact boundary.
                let ix = Int((ux + 1e-7).rounded(.down)), iy = Int((uy + 1e-7).rounded(.down))
                guard ix >= 0, iy >= 0, ix < px.w, iy < px.h else { continue }
                for c in 0..<4 { out[(cy * cw + cx) * 4 + c] = px.at((iy * px.w + ix) * 4 + c) }
            }
        }
        return out
    }

    /// A boxed, left-aligned text (its painted part sits far from the box center) under a clip transform with scale and
    /// rotation: the cropped frame lands on the same canvas pixels as the whole one, through the final layer transform,
    /// with the default pivot (text clips) and with the pivot at the text (captions).
    @Test(arguments: [TextAnimatorEffect.pop, .slide, .blur])
    func croppedFrameLandsWhereTheWholeOneDoesThroughTheLayerTransform(_ effect: TextAnimatorEffect) throws {
        let canvas = SequenceFormat(width: 640, height: 480, frameDuration: Time(1, 30))
        var style = Self.dressed
        style.size = 34; style.alignment = .left
        let template = TextTemplate(name: "t", text: "top left \(effect)", style: style, box: TextBox(width: 520, height: 360))
        let set = Self.animator(effect, .word)
        let ref = try TextGenerator.makeRef(template: template, animations: set)
        let clip = Time(10, 1)
        let base = ClipTransform(position: Vec2(31, -17), scale: Vec2(1.35, 0.8), rotation: 23, opacity: 1, anchor: Vec2(12, -9))
        var compared = 0
        for k in [2, 5, 9] {
            let t = Time(Int64(k), 30)
            let whole = try #require(try TextGenerator.frame(ref: ref, localTime: t, clipDuration: clip, canvas: canvas, scale: 1))
            let cut = try #require(try TextGenerator.frame(ref: ref, localTime: t, clipDuration: clip, canvas: canvas, scale: 1,
                                                           cropped: true))
            // The fixture is one where the crop really moves the raster center.
            #expect(cut.width * cut.height < whole.width * whole.height / 2)
            #expect(abs((cut.x + cut.width / 2) - (whole.x + whole.width / 2)) > 20)
            for pivotAtText in [false, true] {
                let a = whole.layerTransform(base: base, canvas: canvas, pivotAtText: pivotAtText)
                let b = cut.layerTransform(base: base, canvas: canvas, pivotAtText: pivotAtText)
                let pa = Self.composite(whole, a, canvas: canvas), pb = Self.composite(cut, b, canvas: canvas)
                #expect(pa.contains { $0 > 0 })
                var worst: Float = 0
                for i in pa.indices { worst = max(worst, abs(pa[i] - pb[i])) }
                #expect(worst <= Self.tolerance, "\(effect) frame \(k) pivotAtText \(pivotAtText): \(worst)")
                #expect(a.scale == b.scale && a.rotation == b.rotation && a.opacity == b.opacity)
                compared += 1
            }
            // A text clip's default pivot is the whole box center: the whole frame's transform is the one from before.
            let plain = whole.layerTransform(base: base, canvas: canvas)
            #expect(plain.anchor == base.anchor)
        }
        #expect(compared == 6)
    }

    /// A cropped in-between frame of a text in a 4K box touches only the painted part of its scratch memory.
    @Test func croppedRasterCommitsOnlyThePaintedScratchMemory() throws {
        let style = TextStyle(fontName: "Helvetica-Bold", size: 120, color: .white, alignment: .left)
        let text = "small text"
        let layout = TextLayout.layout(text: text, style: style, maxWidth: 3840, boxHeight: 2160)
        let states = try #require(Self.animator(.pop, .word).characterStates(units: TextUnits.segment(layout), clipTime: Time(1, 10),
                                                                             clipDuration: Time(10, 1)))
        let seen = Mutex<(resident: Int, kept: Int, whole: Int)?>(nil)
        TextRenderer.scratchProbe.withLock { $0 = { r, k, w in seen.withLock { $0 = (r, k, w) } } }
        defer { TextRenderer.scratchProbe.withLock { $0 = nil } }
        _ = try #require(try TextRenderer.render(text: text, style: style, maxWidth: 3840, boxHeight: 2160, characterStates: states,
                                                 tight: true))
        let m = try #require(seen.withLock { $0 })
        print("PERF text scratch 4K box: whole \(m.whole / 1024) KiB, kept \(m.kept / 1024) KiB, resident \(m.resident / 1024) KiB")
        #expect(m.whole >= 3840 * 2160 * 8)
        // Core Graphics touches a few pages of its own beside the painted rows (448 KiB of 64800 measured).
        #expect(m.resident <= m.kept * 2 + 2 * 1024 * 1024, "resident \(m.resident) for a kept raster of \(m.kept)")
        #expect(m.resident < m.whole / 16)
    }

    private static func keys(_ cache: TextGenerator.RasterCache, style: TextStyle, text: String, box: TextBox?, count: Int)
        throws -> [[TextCharacterState]] {
        let layout = TextLayout.layout(text: text, style: style, maxWidth: box?.width, boxHeight: box?.height)
        let set = Self.animator(.slide, .character)
        return try (1...count).map {
            try #require(set.characterStates(units: TextUnits.segment(layout), clipTime: Time(Int64($0), 60), clipDuration: Time(10, 1)))
        }
    }

    private static func drain(_ cache: TextGenerator.RasterCache) {
        let deadline = ContinuousClock.now + .seconds(30)
        while cache.pendingCount > 0, ContinuousClock.now < deadline { usleep(500) }
    }

    /// A frame the caller needs while the background has it queued or is drawing it is drawn once, not twice, when the
    /// caller has the time to wait for it (a budget far longer than any raster here, so load never ends it early).
    @Test func aFrameAskedForWhileItIsOnItsWayIsDrawnOnce() throws {
        let cache = TextGenerator.RasterCache(limit: 512 * 1024 * 1024)
        let text = "drawn exactly once", box = TextBox(width: 1600, height: 900)
        let states = try Self.keys(cache, style: Self.dressed, text: text, box: box, count: 8)
        #expect(Set(states).count == 8)
        for round in 0..<3 {
            cache.clear()
            let before = cache.stats
            for s in states { cache.warm(text: text, style: Self.dressed, box: box, highlight: nil, scale: 1, states: s, cropped: true) }
            if round == 1 { usleep(3000) }   // some are being drawn by now
            let wait = TextGenerator.RasterWait(limit: 120)
            for s in states {
                _ = try #require(try cache.raster(text: text, style: Self.dressed, box: box, highlight: nil, scale: 1, states: s,
                                                  cropped: true, wait: wait))
            }
            Self.drain(cache)
            usleep(20_000)   // a background raster that lost its place ends without a trace
            let after = cache.stats
            #expect(after.callerDrawn - before.callerDrawn + after.backgroundDrawn - before.backgroundDrawn == 8,
                    "round \(round): \(before) -> \(after)")
        }
    }

    /// A caller without a budget (seek, scrub, snap guides, export) or with a used-up one never takes a frame it waited
    /// for: it draws every frame itself, whatever the background is doing with the same frames.
    @Test func aCallerWithoutABudgetNeverWaits() throws {
        let cache = TextGenerator.RasterCache(limit: 512 * 1024 * 1024)
        let text = "never waits", box = TextBox(width: 3000, height: 1600)
        var style = Self.dressed
        style.size = 300
        let states = try Self.keys(cache, style: style, text: text, box: box, count: 6)
        for (round, spent) in [false, true, false, true].enumerated() {
            cache.clear()
            Self.drain(cache)
            let before = cache.stats
            for s in states { cache.warm(text: text, style: style, box: box, highlight: nil, scale: 1, states: s, cropped: false) }
            if round >= 2 { usleep(4000) }   // some are being drawn by now
            let wait = spent ? TextGenerator.RasterWait(limit: 0) : nil
            for s in states {
                _ = try #require(try cache.raster(text: text, style: style, box: box, highlight: nil, scale: 1, states: s,
                                                  cropped: false, wait: wait))
            }
            let after = cache.stats
            #expect(after.callerWaited == before.callerWaited, "round \(round)")
            // Every frame the background had not finished by the time it was asked for is the caller's own drawing.
            #expect(after.callerDrawn - before.callerDrawn + after.backgroundDrawn - before.backgroundDrawn >= states.count)
            Self.drain(cache)
        }
    }

    /// Text that is laid out right to left, emoji (bitmap glyphs), several lines and a synthesized italic: the tight
    /// raster is still the painted part of the full one.
    @Test(arguments: [TextAnimatorEffect.fade, .pop, .slide, .typewriter, .blur])
    func tightRasterHoldsForRightToLeftEmojiLinesAndSyntheticItalic(_ effect: TextAnimatorEffect) throws {
        let hebrew = TextStyle(fontName: "ArialHebrew-Bold", size: 80, color: .white, stroke: TextStroke(color: .black, width: 8))
        var arabic = Self.dressed
        arabic.fontName = "GeezaPro-Bold"; arabic.alignment = .right
        // Helvetica Neue Condensed Black has no italic face: the slant is a shear in the font matrix.
        let slanted = TextStyle(fontName: "HelveticaNeue-CondensedBlack", size: 90, color: .white,
                                stroke: TextStroke(color: .black, width: 6), italic: true)
        try tightEqualsFull(effect, text: "שלום עולם\nמילים זזות כאן", styles: [hebrew], scales: [1])
        try tightEqualsFull(effect, text: "مرحبا بالعالم\nكلمات تتحرك", styles: [arabic], units: [.word, .line], scales: [1])
        try tightEqualsFull(effect, text: "fire 🔥 and 🎬 go\n👍🏽 yes 🇩🇪", styles: [Self.plain, Self.dressed], scales: [1, 0.5])
        try tightEqualsFull(effect, text: "one\ntwo words\nthree more words\nfour", styles: [Self.dressed, Self.pill], scales: [1])
        try tightEqualsFull(effect, text: "Wavy jiffy Type\nfly off", styles: [slanted], scales: [1, 0.5])
    }

    /// A spread shadow with a small blur under characters scaled far up: the spread is drawn inside the character's
    /// transform and grows with it, and the tight raster holds all of it.
    @Test func tightRasterHoldsASpreadShadowUnderAScaledCharacter() throws {
        var shadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.9), offsetX: 9, offsetY: 13, blur: 1)
        shadow.spread = 16
        var worstInside: Float = 0, worstOutside: Float = 0, cases = 0
        for stroke in [nil, TextStroke(color: .black, width: 6)] as [TextStroke?] {
            let style = TextStyle(fontName: "Helvetica-Bold", size: 48, color: .white, stroke: stroke, shadow: shadow)
            let text = "big Spread\nlow"
            let box = TextBox(width: 1400, height: 900)
            let layout = TextLayout.layout(text: text, style: style, maxWidth: box.width, boxHeight: box.height)
            let count = TextUnits.segment(layout).characters.count
            #expect(count > 8)
            for (scale, unit) in [(2.5, TextAnimatorUnit.character), (4, .character), (3, .word), (0.4, .character)] {
                // Every second character moves; the rest stay at rest beside it.
                let states = (0..<count).map { i in
                    i % 2 == 0 ? TextCharacterState(in: TextUnitState(scale: scale, offsetX: 12, offsetY: -20), out: .rest, inUnit: unit)
                               : TextCharacterState(in: .rest, out: .rest)
                }
                for s in [1.0, 0.5] {
                    let full = try #require(try TextRenderer.render(text: text, style: style, maxWidth: box.width, boxHeight: box.height,
                                                                    scale: s, characterStates: states))
                    let tight = try #require(try TextRenderer.render(text: text, style: style, maxWidth: box.width, boxHeight: box.height,
                                                                     scale: s, characterStates: states, tight: true))
                    let c = try #require(compare(tight: tight, full: full), "tight raster off the pixel grid")
                    #expect(tight.pixelWidth * tight.pixelHeight < full.pixelWidth * full.pixelHeight)
                    worstInside = max(worstInside, c.inside); worstOutside = max(worstOutside, c.outside); cases += 1
                }
            }
        }
        #expect(cases == 16)
        #expect(worstInside <= Self.tolerance, "tight differs from full by \(worstInside)")
        #expect(worstOutside <= Self.tolerance, "the full raster paints \(worstOutside) outside the tight one")
    }

    /// `clear()` (memory pressure) cancels what is in flight: nothing comes back into the cache afterwards.
    @Test func clearingCancelsTheRastersInFlight() throws {
        let cache = TextGenerator.RasterCache(limit: 512 * 1024 * 1024)
        let text = "gone after clear", box = TextBox(width: 3000, height: 1600)
        var style = Self.dressed
        style.size = 300
        let states = try Self.keys(cache, style: style, text: text, box: box, count: 8)
        for wait in [0, 2000, 6000] as [UInt32] {
            for s in states { cache.warm(text: text, style: style, box: box, highlight: nil, scale: 1, states: s, cropped: true) }
            usleep(wait)
            cache.clear()
            #expect(cache.pendingCount == 0)
            for _ in 0..<40 { usleep(5000); #expect(cache.bytes == 0) }
        }
        // And the cache still works afterwards.
        cache.warm(text: text, style: style, box: box, highlight: nil, scale: 1, states: states[0], cropped: true)
        Self.drain(cache)
        #expect(cache.bytes > 0)
    }

    /// The background rasters never hold more scratch memory than the budget (one alone may exceed it).
    @Test func backgroundRastersStayUnderTheInFlightByteBudget() throws {
        let cache = TextGenerator.RasterCache(limit: 512 * 1024 * 1024, inFlightLimit: 1)
        let text = "one at a time", box = TextBox(width: 1600, height: 900)
        let states = try Self.keys(cache, style: Self.dressed, text: text, box: box, count: 8)
        var one = 0
        for _ in 0..<4 {
            for s in states { cache.warm(text: text, style: Self.dressed, box: box, highlight: nil, scale: 1, states: s, cropped: true) }
            Self.drain(cache)
        }
        for s in states {   // what a single raster of this text holds at most
            let r = try #require(try cache.raster(text: text, style: Self.dressed, box: box, highlight: nil, scale: 1, states: s, cropped: true))
            one = max(one, r.pixelWidth * r.pixelHeight * 16)
        }
        #expect(cache.stats.backgroundDrawn > 0)
        #expect(cache.peakInFlightBytes > 0 && cache.peakInFlightBytes <= one, "peak \(cache.peakInFlightBytes), one raster \(one)")
        #expect(TextGenerator.animatedLaneWidth >= 2 && TextGenerator.animatedLaneWidth <= 4)
    }

    @Test func animatedCacheStaysUnderItsByteLimit() throws {
        TextGenerator.clearCache()
        let canvas = SequenceFormat(width: 3840, height: 2160, frameDuration: Time(1, 30))
        var style = Self.dressed
        style.size = 400
        let set = Self.animator(.slide, .character)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "A very wide line of text", style: style),
                                            animations: set)
        for k in 1..<60 {
            _ = try TextGenerator.frame(ref: ref, localTime: Time(Int64(k), 60), clipDuration: Time(10, 1), canvas: canvas, scale: 1)
            #expect(TextGenerator.animatedCacheBytes <= TextGenerator.animatedCacheByteLimit)
        }
        #expect(TextGenerator.animatedCacheBytes > TextGenerator.animatedCacheByteLimit / 2)   // it really filled up
        TextGenerator.clearCache()
    }

    @Test func memosReturnWhatTheUnmemoizedCodeReturns() throws {
        let style = Self.pill
        let text = "Donaudampfschifffahrtsgesellschaftskapitaen"
        let first = CaptionLayout.fittingSize(text: text, style: style, boxWidth: 300)
        let again = CaptionLayout.fittingSize(text: text, style: style, boxWidth: 300)
        FontResolver.fontsChanged()
        let fresh = CaptionLayout.fittingSize(text: text, style: style, boxWidth: 300)
        #expect(first == again && first == fresh)
        #expect(first < style.size)

        let a = TextLayout.layout(text: text, style: style, maxWidth: 300)
        FontResolver.fontsChanged()
        let b = TextLayout.layout(text: text, style: style, maxWidth: 300)
        #expect(a.bounds == b.bounds && a.lines.count == b.lines.count)

        let template = TextTemplate(name: "t", text: text, style: style)
        let set = Self.animator(.fade, .word)
        let r1 = try TextGenerator.makeRef(template: template, animations: set)
        let r2 = try TextGenerator.makeRef(template: template, animations: set)
        TextGenerator.clearCache()
        let r3 = try TextGenerator.makeRef(template: template, animations: set)
        #expect(r1 == r2 && r1 == r3)
        let other = try TextGenerator.makeRef(template: template, animations: nil)
        #expect(other != r1)
    }

    @Test func lazyImageShowsTheSamePictureAsTheLinearBuffer() throws {
        let r = try #require(try TextRenderer.render(text: "Lazy", style: Self.plain, maxWidth: nil))
        let p = RasterProbe(r.image)
        #expect(p.w == r.pixelWidth && p.h == r.pixelHeight)
        let lin = LinearPixels(r.linearBuffer)
        var mismatched = 0
        for y in 0..<p.h {
            for x in 0..<p.w {
                let opaque8: Bool = p.px(x, y).a > 127
                let alpha: Float = lin.at((y * lin.w + x) * 4 + 3)
                if opaque8 != (alpha > 0.5) { mismatched += 1 }
            }
        }
        #expect(mismatched == 0)
        #expect(RasterProbe(r.image).data == p.data)   // drawn once, the same picture each time
    }
}
#endif
