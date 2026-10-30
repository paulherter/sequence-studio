import Foundation
import Testing
import SQCore
@testable import SQText

/// The text box without a raster (`TextGenerator.portableBox`, the monitor's text frame on Windows) and the caret map of
/// the portable raster (`PortableTextRenderer.caretMap`, the on-canvas field's caret and click positions).
@Suite struct PortableTextCaretTests {
    private let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))

    @Test func boxMatchesThePortableFrame() throws {
        let fade = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)])],
                                    duration: Time(1, 5), anchor: .start)
        var style = TextStyle(size: 90, color: .white)
        style.stroke = TextStroke(color: RGBAColor(red: 0, green: 0, blue: 0), width: 4)
        for box in [nil, TextBox(width: 900, height: 500)] {
            let template = TextTemplate(name: "t", text: "Hello\nWorld", style: style, box: box)
            let ref = try TextGenerator.makeRef(template: template, animations: AnimationSet(in: fade, out: nil))
            for t in [Time.zero, Time(1, 10)] {
                let f = try #require(try TextGenerator.portableFrame(ref: ref, localTime: t, clipDuration: Time(3, 1), canvas: canvas))
                let b = try #require(try TextGenerator.portableBox(ref: ref, localTime: t, clipDuration: Time(3, 1), canvas: canvas))
                #expect(abs(b.x - f.x) < 1e-9 && abs(b.y - f.y) < 1e-9)
                #expect(abs(b.width - f.width) < 1e-9 && abs(b.height - f.height) < 1e-9)
                #expect(b.offsetX == f.offsetX && b.offsetY == f.offsetY && b.scale == f.scale && b.rotation == f.rotation)
                let r = try #require(TextGenerator.portableGraphicsRect(ref: ref, localTime: t, clipDuration: Time(3, 1), canvas: canvas))
                #expect(abs(r.minX - (f.x - 960 + f.offsetX)) < 1e-9 && abs(r.width - f.width) < 1e-9)
            }
        }
        let empty = try TextGenerator.makeRef(template: TextTemplate(name: "e", text: "", style: style), animations: nil)
        #expect(try TextGenerator.portableBox(ref: empty, localTime: .zero, clipDuration: Time(3, 1), canvas: canvas) == nil)
    }

    @Test func caretsFollowTheGlyphsLineByLine() throws {
        var style = TextStyle(size: 100)
        style.alignment = .center
        let text = "Wide line\nab"
        let map = try #require(PortableTextRenderer.caretMap(text: text, style: style, maxWidth: nil))
        let raster = try #require(PortableTextRenderer.render(text: text, style: style, maxWidth: nil))
        #expect(map.carets.count == text.count + 1)
        #expect(map.lines.count == 2)
        // "Wide line" sits on line 0, its end (before the break) too; "ab" and the end on line 1.
        #expect(map.carets[0..<10].allSatisfy { $0.line == 0 })
        #expect(map.carets[10...].allSatisfy { $0.line == 1 })
        for r in [0..<10, 10..<13] {
            let xs = map.carets[r].map(\.x)
            #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }, "carets grow along a line")
        }
        // Each line's carets span its typographic width, placed where the raster's layout aligns it (ink origin = 0).
        for (li, range) in [(0, 0...9), (1, 10...12)] {
            let l = raster.layout.lines[li]
            let first = map.carets[range.lowerBound].x, last = map.carets[range.upperBound].x
            #expect(abs(first - (l.x - raster.originX)) < 0.01)
            #expect(abs((last - first) - l.width) < 1, "line \(li): \(last - first) vs \(l.width)")
            #expect(abs(map.lines[li].top - (l.y - raster.originY)) < 1e-9 && map.lines[li].height == l.height)
        }
        // Centered: the short line starts right of the long one.
        #expect(map.carets[10].x > map.carets[0].x + 50)
    }

    @Test func wrappedSpaceAndEmptyLinesKeepACaret() throws {
        let style = TextStyle(size: 60)
        let text = "one two three\n\nx"
        let map = try #require(PortableTextRenderer.caretMap(text: text, style: style, maxWidth: 200))
        #expect(map.carets.count == text.count + 1)
        #expect(map.lines.count >= 4)
        let lines = map.carets.map(\.line)
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0 <= $1 }, "lines never go back")
        #expect(lines.last == map.lines.count - 1)
        // The empty paragraph has a caret of its own line.
        let emptyIndex = text.distance(from: text.startIndex, to: text.range(of: "\n\n")!.lowerBound) + 1
        #expect(map.carets[emptyIndex].line == map.lines.count - 2)
    }

    @Test func caretIndexFindsTheNearestCharacter() throws {
        let style = TextStyle(size: 100)
        let text = "abc\nde"
        let map = try #require(PortableTextRenderer.caretMap(text: text, style: style, maxWidth: nil))
        for i in 0...text.count {
            let c = map.carets[i]
            let p = (x: c.x + 0.1, y: map.lines[c.line].top + map.lines[c.line].height / 2)
            #expect(map.index(atX: p.x, y: p.y) == i, "caret \(i)")
        }
        #expect(map.index(atX: -500, y: -500) == 0)
        #expect(map.index(atX: 5000, y: 5000) == text.count)
    }
}
