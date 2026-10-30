#if canImport(CoreText)
import Testing
import Foundation
import SQCore
@testable import SQText

/// FB-Y: caption position (top/middle/bottom, left/center/right, free offset), the caption pop pivot at the text center,
/// and the softer pop. Monitor (TextGenerator + compositor anchor) and burn-in (`CaptionLayout.drawCenter`) must agree.
@Suite(.serialized) struct CaptionPositionLayoutTests {
    static let w = 1080.0, h = 1920.0
    static let style = TextStyle(fontName: "Helvetica", size: 64, weight: .bold)

    /// The drawn text block (union of the line rects) in canvas pixels (origin top-left) for `position`.
    func textRect(_ text: String, _ position: CaptionPosition) throws -> TextRect {
        let t = CaptionLayout.template(text: text, style: Self.style, canvasWidth: Self.w, canvasHeight: Self.h, position: position)
        let box = try #require(t.box)
        let layout = TextLayout.layout(text: t.text, style: t.style, maxWidth: box.width, boxHeight: box.height)
        let c = CaptionLayout.boxCentre(canvasWidth: Self.w, canvasHeight: Self.h, position: position)
        let left = Self.w / 2 + c.x - box.width / 2, top = Self.h / 2 + c.y - box.height / 2
        let r = try #require(layout.lines.map(\.rect).reduce(nil as TextRect?) { acc, r in acc.map { $0.union(r) } ?? r })
        return r.offsetBy(dx: left, dy: top)
    }

    @Test func defaultPositionIsTheOldBottomPlacement() {
        let old = CaptionLayout.boxCentre(canvasWidth: Self.w, canvasHeight: Self.h)
        let new = CaptionLayout.boxCentre(canvasWidth: Self.w, canvasHeight: Self.h, position: .default)
        #expect(old.x == new.x && old.y == new.y)
        #expect(abs(old.y - (Self.h * (0.5 - CaptionLayout.bottomMargin) - Self.h * CaptionLayout.boxHeightFraction / 2)) < 1e-9)
    }

    @Test func verticalChoicesMoveTheText() throws {
        let margin = Self.h * CaptionLayout.bottomMargin
        let bottom = try textRect("Hello", .default)
        #expect(abs(bottom.maxY - (Self.h - margin)) < 1)
        let top = try textRect("Hello", CaptionPosition(vertical: .top))
        #expect(abs(top.y - margin) < 1)
        let middle = try textRect("Hello", CaptionPosition(vertical: .middle))
        #expect(abs(middle.y + middle.height / 2 - Self.h / 2) < 1)
    }

    @Test func horizontalChoicesAlignTheTextInTheSafeBox() throws {
        let side = Self.w * (1 - CaptionLayout.widthFraction) / 2
        let left = try textRect("Hello", CaptionPosition(horizontal: .left))
        #expect(abs(left.x - side) < 1)
        let right = try textRect("Hello", CaptionPosition(horizontal: .right))
        #expect(abs(right.maxX - (Self.w - side)) < 1)
        let centre = try textRect("Hello", .default)
        #expect(abs(centre.x + centre.width / 2 - Self.w / 2) < 1)
    }

    @Test func offsetMovesTheBoxByAFractionOfTheCanvas() throws {
        let a = try textRect("Hello", CaptionPosition(vertical: .middle))
        let b = try textRect("Hello", CaptionPosition(vertical: .middle, offsetX: 0.1, offsetY: -0.25))
        #expect(abs((b.x - a.x) - 0.1 * Self.w) < 0.01)
        #expect(abs((b.y - a.y) + 0.25 * Self.h) < 0.01)
    }

    @Test func libraryCarriesTheKitPosition() {
        let p = CaptionPosition(vertical: .top, horizontal: .left, offsetX: 0.05)
        let lib = CaptionPresetLibrary.base.applying(StyleKit(captionPosition: p))
        #expect(lib.position == p)
        #expect(lib.adding(.default, id: "x").position == p)
        #expect(CaptionPresetLibrary.base.applying(StyleKit()).position == .default)
    }

    // MARK: Pop pivot

    /// Monitor: the compositor anchor puts the pivot at the text center, whatever the box, shadow or position.
    @Test(arguments: [CaptionPosition.default, CaptionPosition(vertical: .top, horizontal: .left, offsetX: 0.1)])
    func popPivotIsTheTextCentre(_ position: CaptionPosition) throws {
        var s = Self.style
        s.shadow = TextShadow(color: .black, angle: 135, distance: 12, blur: 10)
        let t = CaptionLayout.template(text: "Pop me", style: s, canvasWidth: Self.w, canvasHeight: Self.h, position: position)
        let canvas = SequenceFormat(width: Int(Self.w), height: Int(Self.h), frameDuration: Time(1, 30))
        let ref = try TextGenerator.makeRef(template: t, animations: nil)
        let f = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(2, 1), canvas: canvas, scale: 1))
        let c = CaptionLayout.boxCentre(canvasWidth: Self.w, canvasHeight: Self.h, position: position)
        let base = ClipTransform(position: Vec2(c.x, c.y))
        let plain = f.layerTransform(base: base, canvas: canvas)
        let pivoted = f.layerTransform(base: base, canvas: canvas, pivotAtText: true)
        // At rest the layer lands where it did (position - anchor is the raster center).
        #expect(abs(pivoted.position.x - pivoted.anchor.x - plain.position.x) < 1e-9)
        #expect(abs(pivoted.position.y - pivoted.anchor.y - plain.position.y) < 1e-9)
        // The pivot (anchor point, which the compositor keeps fixed) is the center of the text lines.
        let box = try #require(t.box)
        let layout = TextLayout.layout(text: t.text, style: t.style, maxWidth: box.width, boxHeight: box.height)
        let lines = try #require(layout.lines.map(\.rect).reduce(nil as TextRect?) { acc, r in acc.map { $0.union(r) } ?? r })
        let cx = Self.w / 2 + c.x - box.width / 2 + lines.x + lines.width / 2
        let cy = Self.h / 2 + c.y - box.height / 2 + lines.y + lines.height / 2
        #expect(abs(Self.w / 2 + pivoted.position.x - cx) < 0.01)
        #expect(abs(Self.h / 2 + pivoted.position.y - cy) < 0.01)
    }

    /// Burn-in: the raster center of a scaled, rotated caption is where the monitor's anchored layer puts it.
    @Test func burnInMatchesTheMonitorUnderScaleAndRotation() throws {
        let t = CaptionLayout.template(text: "Pop me\ntwice", style: Self.style, canvasWidth: Self.w, canvasHeight: Self.h,
                                       position: CaptionPosition(vertical: .middle, horizontal: .right))
        let canvas = SequenceFormat(width: Int(Self.w), height: Int(Self.h), frameDuration: Time(1, 30))
        let ref = try TextGenerator.makeRef(template: t, animations: nil)
        let f = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(2, 1), canvas: canvas, scale: 1))
        let c = CaptionLayout.boxCentre(canvasWidth: Self.w, canvasHeight: Self.h, position: CaptionPosition(vertical: .middle, horizontal: .right))
        var tr = f.layerTransform(base: ClipTransform(position: Vec2(c.x, c.y)), canvas: canvas, pivotAtText: true)
        let scale = 0.8, rot = 20.0
        tr.scale = Vec2(scale, scale); tr.rotation = rot
        // Compositor: layer center (local 0,0) lands at canvas/2 + position + R * S * (0 - anchor).
        let rad = rot * .pi / 180
        let px = -tr.anchor.x * scale, py = -tr.anchor.y * scale
        let monitor = (x: Self.w / 2 + tr.position.x + cos(rad) * px - sin(rad) * py,
                       y: Self.h / 2 + tr.position.y + sin(rad) * px + cos(rad) * py)
        let raster = try #require(try TextRenderer.render(text: t.text, style: t.style, maxWidth: t.box?.width, boxHeight: t.box?.height))
        let rc = CaptionLayout.rasterCentre(canvasWidth: Self.w, canvasHeight: Self.h, originX: raster.originX, originY: raster.originY,
                                            width: Double(raster.pixelWidth), height: Double(raster.pixelHeight),
                                            position: CaptionPosition(vertical: .middle, horizontal: .right))
        let pivot = CaptionLayout.pivot(of: raster)
        let burn = CaptionLayout.drawCentre(rasterCentre: rc, pivot: pivot, scale: scale, rotationDegrees: rot, offset: .zero)
        #expect(abs(monitor.x - burn.x) < 0.01 && abs(monitor.y - burn.y) < 0.01, "monitor \(monitor) burn \(burn)")
    }

    // MARK: Softer pop

    @Test func captionPopIsGentleAndEasesOut() throws {
        let pop = KeyframeTemplate.captionPop
        let scale = try #require(pop.tracks.first { $0.property == "scale" })
        let samples = stride(from: 0, through: 400, by: 5).compactMap { scale.value(at: Time(Int64($0), 1000)) }
        let start = try #require(samples.first), peak = try #require(samples.max())
        #expect(start >= 0.95 && start < 1)                     // was 0.9
        #expect(peak > 1 && peak <= 1.03)                       // was 1.05
        #expect(abs(try #require(scale.value(at: pop.duration)) - 1) < 1e-9)
        #expect(pop.duration >= Time(1, 5))                      // settles over at least 0.2 s (was 0.13 s, linear)
        // Ease-out toward the end: halfway through the settle more than half of the way back is done.
        let peakKey = try #require(scale.track.keys.dropFirst().first)
        let span = pop.duration - peakKey.time
        let mid = peakKey.time + Time(span.value, span.timescale * 2)
        let v = try #require(scale.value(at: mid))
        #expect((peakKey.value - v) / (peakKey.value - 1) > 0.6)
    }

    // MARK: Pill off on a look with its own box

    @Test func hiddenBackgroundDropsTheBaseLooksBoxButNotTheKitPill() throws {
        let lib = CaptionPresetLibrary.base
        var kit = StyleKit(caption: CaptionStyleSpec(baseStyle: CaptionPill.styleID, hidesBackground: true))
        let off = try #require(kit.captionStyle(base: lib))
        #expect(off.background == nil)
        #expect(off.size == lib.style(for: CaptionPill.styleID).size)   // the look stays the pill look, only the box goes
        kit.caption?.usesPill = true
        kit.pill = StylePill(color: .literal(EffectColor(red: 1, green: 0, blue: 0)), horizontalEm: 0.5)
        let on = try #require(kit.captionStyle(base: lib))
        #expect(on.background?.padding.horizontal == (on.size * 0.5).rounded())
    }
}
#endif
