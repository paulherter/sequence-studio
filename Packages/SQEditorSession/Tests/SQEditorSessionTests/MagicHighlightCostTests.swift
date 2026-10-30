import AppKit
import Testing
import SQCore
@testable import SQEditorSession

@Suite struct MagicHighlightCostTests {
    private func matte(_ w: Int, _ h: Int) -> SubjectMatte {
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { v[y * w + x] = (x > w / 4 && x < w * 3 / 4) ? Float(y % 7) / 6 : 0 } }
        return SubjectMatte(width: w, height: h, values: v)
    }

    @Test func pixelsAreStraightTintTimesMatte() throws {
        let m = SubjectMatte(width: 2, height: 1, values: [1, 0])
        let img = try #require(MagicHighlight.image(m, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), alpha: 0.5))
        let data = try #require(img.dataProvider?.data as Data?)
        #expect(data[3] == 127 || data[3] == 128)
        #expect(data[0] == data[3])            // premultiplied red
        #expect(data[1] == 0 && data[2] == 0)
        #expect(Array(data[4..<8]) == [0, 0, 0, 0])
    }

    /// A tint image of a full-HD matte is made once per scrubbed frame: it has to stay far under a frame budget, also in Debug.
    @Test func imageCostStaysInBudget() throws {
        let m = matte(1920, 1080)
        _ = MagicHighlight.image(m)
        let t0 = ContinuousClock.now
        for _ in 0..<5 { _ = MagicHighlight.image(m, alpha: 0.3) }
        let ms = (ContinuousClock.now - t0) / 5
        let v = Double(ms.components.attoseconds) / 1e15
        print("SQ_PLAY_PROBE magicHighlight1080 ms=\(v)")
        #expect(v < 30)      // was ~390 ms with the per-pixel loop in Debug, ~19 ms now
    }
}
