import Foundation
import Testing
import SQDrawKit
import SQUIKit

@Suite("Color picker control")
struct ColorPickerControlTests {
    private let red = SQColorValue(h: 0, s: 1, b: 1)

    @Test func dragInTheFieldSetsSaturationAndBrightness() {
        var p = ColorPickerControl(value: red)
        let f = p.fieldFrame
        let o = p.mouseDown(at: CGPoint(x: f.midX, y: f.minY + f.height * 0.25))
        #expect(o == .changed)
        #expect(abs(p.value.s - 0.5) < 0.01 && abs(p.value.b - 0.75) < 0.01)
        _ = p.mouseDragged(to: CGPoint(x: f.maxX + 50, y: f.maxY + 50))     // clamped
        #expect(p.value.s == 1 && p.value.b == 0)
        p.mouseUp()
        let after = p.mouseDragged(to: CGPoint(x: f.minX, y: f.minY))
        #expect(after == .none)
    }

    @Test func hueBarCapsBelowOneAndAlphaBarOnlyWhenShown() {
        var p = ColorPickerControl(value: red)
        #expect(p.alphaFrame == nil)
        let h = p.hueFrame
        _ = p.mouseDown(at: CGPoint(x: h.maxX - 1, y: h.midY))
        #expect(p.value.h == 0.9999)
        var a = ColorPickerControl(value: red, showsAlpha: true)
        let af = try! #require(a.alphaFrame)
        _ = a.mouseDown(at: CGPoint(x: af.minX, y: af.midY))
        #expect(a.value.a == 0)
        #expect(a.size.height > p.size.height)
    }

    @Test func hexEditAppliesEveryValidTextAndKeepsAlpha() {
        var p = ColorPickerControl(value: SQColorValue(h: 0, s: 1, b: 1, a: 0.5), showsAlpha: true)
        _ = p.mouseDown(at: CGPoint(x: p.hexFrame.midX, y: p.hexFrame.midY))
        #expect(p.hex?.string == "FF0000")
        for ch in "00FF" { _ = p.key(.character(ch), modifiers: []) }
        #expect(p.value.hex == "0000FF")        // "00F" applied, "00FF" is not a color
        _ = p.key(.character("0"), modifiers: [])
        let r = p.key(.character("0"), modifiers: [])
        #expect(r.taken && r.outcome == .changed)
        #expect(p.value.hex == "00FF00" && p.value.a == 0.5)
        _ = p.key(.enter, modifiers: [])
        #expect(p.hex == nil)
    }

    @Test func recentsShowAfterCommitAndPickWithoutAlpha() {
        var p = ColorPickerControl(value: red)
        let empty = p.size.height
        let first = p.commitRecent()
        #expect(first == false)       // nothing changed
        _ = p.mouseDown(at: CGPoint(x: p.fieldFrame.midX, y: p.fieldFrame.midY))
        p.mouseUp()
        let second = p.commitRecent()
        #expect(second)
        #expect(p.recents.count == 1 && p.size.height > empty)
        p.recents = ["0000FF80"] + p.recents
        let d = p.recentFrame(0)
        let o = p.mouseDown(at: CGPoint(x: d.midX, y: d.midY))
        #expect(o == .changed)
        #expect(p.value.hex == "0000FF" && p.value.a == 1)
    }

    @Test func eyedropperIsAHostHookAndPickKeepsAlpha() {
        var p = ColorPickerControl(value: SQColorValue(h: 0, s: 1, b: 1, a: 0.25), showsAlpha: true)
        let e = try! #require(p.eyedropperFrame)
        let o = p.mouseDown(at: CGPoint(x: e.midX, y: e.midY))
        #expect(o == .eyedropper)
        let picked = p.pick(SQColorValue(r: 0, g: 0, b: 1))
        #expect(picked == .changed)
        #expect(p.value.hex == "0000FF" && p.value.a == 0.25)
        let none = ColorPickerControl(value: red, showsEyedropper: false)
        #expect(none.eyedropperFrame == nil && none.hexFrame.maxX > p.hexFrame.maxX)
    }

    @Test func popoverFlipsAboveAndStaysOnScreen() {
        let p = ColorPickerControl(value: red)
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let below = p.frame(anchor: CGRect(x: 100, y: 50, width: 38, height: 20), in: screen)
        #expect(below.minY == 74)
        let above = p.frame(anchor: CGRect(x: 790, y: 560, width: 38, height: 20), in: screen)
        #expect(above.maxY == 556 && above.maxX <= 794)
    }

    @Test func drawsTheFieldColorUnderTheCursorPoint() {
        let p = ColorPickerControl(value: red)
        let s = p.size
        var c = Canvas(width: Float(s.width), height: Float(s.height), atlas: nil, scale: 1)
        p.draw(&c, theme: DrawTheme())
        let img = SoftwareRenderer.render(c.list, width: Int(s.width), height: Int(s.height), clear: .black, atlas: nil)
        // Top left of the field (inside the corner): saturation ~0, brightness ~1, so white-ish.
        let f = p.fieldFrame, x = Int(f.minX) + 10, y = Int(f.minY) + 4
        let px = img.pixels[(y * img.width + x) * 4 ..< (y * img.width + x) * 4 + 3]
        #expect(px.allSatisfy { $0 > 200 })
        // Bottom of the field: black.
        let yb = Int(f.maxY) - 2
        #expect(img.pixels[(yb * img.width + x) * 4] < 20)
    }
}
