import Testing
import SQCore
@testable import SQText

struct TextResizeTests {
    @Test func resizeScalesSizeTrackingSpacingAndBox() {
        let t = TextTemplate(name: "t", text: "Hi", style: TextStyle(size: 40, lineSpacing: 4, tracking: 2),
                             box: TextBox(width: 400, height: 100))
        let r = t.resized(by: 1.5)
        #expect(r.style.size == 60)
        #expect(r.style.tracking == 3)
        #expect(r.style.lineSpacing == 6)
        #expect(r.box == TextBox(width: 600, height: 150))
    }

    @Test func resizeClampsAndIgnoresBadFactors() {
        let t = TextTemplate(name: "t", text: "Hi", style: TextStyle(size: 40))
        #expect(t.resized(by: 0.0001).style.size == 1)
        #expect(t.resized(by: 1000).style.size == 2000)
        #expect(t.resized(by: .nan) == t)
        #expect(t.resized(by: -1) == t)
    }

    @Test func handleFactorIsTheMeanOfBothAxes() {
        #expect(TextTemplate.resizeFactor(from: Vec2(1, 1), to: Vec2(2, 2)) == 2)
        #expect(abs(TextTemplate.resizeFactor(from: Vec2(1, 1), to: Vec2(4, 1)) - 2) < 1e-12)   // edge handle: one axis
        #expect(TextTemplate.resizeFactor(from: Vec2(0, 1), to: Vec2(2, 2)) == 1)
        #expect(TextTemplate.resizeFactor(from: Vec2(1, 1), to: Vec2(0, 2)) == 1)
    }
}
