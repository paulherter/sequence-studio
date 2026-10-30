#if canImport(CoreText)
import Testing
import Foundation
import CoreText
import SQCore
@testable import SQText

@Suite struct AreaTextTests {
    func style(_ v: TextVerticalAlignment = .top, tracking: Double = 0, italic: Bool = false,
               align: TextAlignment = .left) -> TextStyle {
        TextStyle(fontName: "Helvetica", size: 32, alignment: align, tracking: tracking, italic: italic, verticalAlignment: v)
    }
    let long = "The quick brown fox jumps over the lazy dog"

    @Test func boxWrapsAndBoundsAreTheBox() {
        let r = TextLayout.layout(text: long, style: style(), maxWidth: 200, boxHeight: 300)
        #expect(r.lines.count > 1)
        #expect(r.bounds == TextRect(x: 0, y: 0, width: 200, height: 300))
        #expect(r.lines.allSatisfy { $0.x + $0.width <= 200.01 })
    }

    @Test func verticalAlignmentPlacesTheBlock() {
        let top = TextLayout.layout(text: "Hi", style: style(.top), maxWidth: 200, boxHeight: 300)
        let mid = TextLayout.layout(text: "Hi", style: style(.middle), maxWidth: 200, boxHeight: 300)
        let bot = TextLayout.layout(text: "Hi", style: style(.bottom), maxWidth: 200, boxHeight: 300)
        let h = top.lines[0].height
        #expect(top.lines[0].y == 0)
        #expect(abs(mid.lines[0].y - (300 - h) / 2) < 0.01)
        #expect(abs(bot.lines[0].y - (300 - h)) < 0.01)
    }

    @Test func pointTextIgnoresVerticalAlignment() {
        let a = TextLayout.layout(text: "Hi", style: style(.bottom), maxWidth: nil)
        #expect(a.lines[0].y == 0)
    }

    @Test func backgroundHugsTheTextNotTheBox() {
        var s = style(.middle)
        s.background = TextBackground(color: .black, padding: BoxPadding(horizontal: 10, vertical: 5))
        let r = TextLayout.layout(text: "Hi", style: s, maxWidth: 200, boxHeight: 300)
        let bg = r.backgroundRect!
        #expect(bg.height < 100)
        #expect(abs(bg.y - (r.lines[0].y - 5)) < 0.01)
        #expect(r.inkBounds.height >= 300)
    }

    @Test func trackingWidensLines() {
        let plain = TextLayout.layout(text: "Hello", style: style(), maxWidth: nil).lines[0].width
        let wide = TextLayout.layout(text: "Hello", style: style(tracking: 10), maxWidth: nil).lines[0].width
        #expect(wide > plain + 30)
        let tight = TextLayout.layout(text: "Hello", style: style(tracking: -2), maxWidth: nil).lines[0].width
        #expect(tight < plain)
    }

    @Test func italicChangesTheFont() {
        let n = FontResolver.font(for: style())
        let i = FontResolver.font(for: style(italic: true))
        let slanted = CTFontGetSymbolicTraits(i).contains(.italicTrait) || abs(CTFontGetSlantAngle(i)) > 1
        #expect(slanted)
        #expect(!CTFontGetSymbolicTraits(n).contains(.italicTrait))
    }

    @Test func shadowAngleDistanceRoundTrips() {
        let s = TextShadow(color: .black, angle: 135, distance: 10, blur: 4)
        #expect(s.offsetX > 0 && s.offsetY > 0)
        #expect(abs(s.angle - 135) < 1e-6 && abs(s.distance - 10) < 1e-9)
        let up = TextShadow(color: .black, angle: 90, distance: 5, blur: 0)   // light from above: shadow falls down
        #expect(abs(up.offsetX) < 1e-9 && up.offsetY > 4.99)
    }

    @Test func angleSurvivesZeroDistance() throws {
        let s = TextShadow(color: .black, angle: 60, distance: 0, blur: 2)
        #expect(abs(s.angle - 60) < 1e-9)
        let back = try JSONDecoder().decode(TextShadow.self, from: JSONEncoder().encode(s))
        #expect(abs(back.angle - 60) < 1e-9)
        let again = TextShadow(color: .black, angle: back.angle, distance: 8, blur: 2)
        #expect(abs(again.angle - 60) < 1e-6)
        #expect(TextShadow(color: .black, offsetX: 0, offsetY: 0, blur: 0).angle == 135)
    }

    @Test func oldStyleJSONDecodes() throws {
        let json = #"{"fontName":"Helvetica","size":40,"weight":400,"color":{"red":1,"green":1,"blue":1,"alpha":1},"alignment":"center","lineSpacing":0}"#
        let s = try JSONDecoder().decode(TextStyle.self, from: Data(json.utf8))
        #expect(s.tracking == 0 && !s.italic && s.verticalAlignment == .top)
    }

    @Test func templateBoxRoundTripsAndOldTemplatesHaveNone() throws {
        var t = TextTemplate(name: "A", text: "x", style: style())
        #expect(t.box == nil)
        t.box = TextBox(width: 500, height: 200)
        let back = try TextTemplate.decode(from: t.encoded())
        #expect(back.box == TextBox(width: 500, height: 200))
    }

    @Test func areaTextRendersAndIsCenteredAsABox() throws {
        var t = TextTemplate(name: "A", text: long, style: style(.middle, align: .center))
        t.box = TextBox(width: 400, height: 300)
        let ref = try TextGenerator.makeRef(template: t, animations: nil)
        let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let f = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(5, 1), canvas: canvas, scale: 1))
        #expect(f.width >= 400 && f.height >= 300)
        #expect(abs((f.x + f.width / 2) - 960) < 1 && abs((f.y + f.height / 2) - 540) < 1)
    }
}
#endif
