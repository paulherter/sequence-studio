import Foundation
import Testing
@testable import SQCore

/// FB-Y: where captions sit (top/middle/bottom, left/center/right, free offset), stored in the project's style kit.
@Suite struct CaptionPositionTests {
    @Test func defaultIsBottomCentreWithoutOffset() {
        let p = CaptionPosition.default
        #expect(p.vertical == .bottom && p.horizontal == .center && p.offsetX == 0 && p.offsetY == 0)
    }

    @Test func offsetIsClampedAndFinite() {
        let p = CaptionPosition(vertical: .top, horizontal: .left, offsetX: 3, offsetY: -.infinity)
        #expect(p.offsetX == CaptionPosition.maxOffset)
        #expect(p.offsetY == 0)
        #expect(CaptionPosition(offsetY: -0.7).offsetY == -0.5)
    }

    @Test func kitRoundTripsThePositionAndOldKitsDecodeWithout() throws {
        var k = StyleKit()
        k.captionPosition = CaptionPosition(vertical: .top, horizontal: .right, offsetX: 0.1, offsetY: -0.05)
        let back = try JSONDecoder().decode(StyleKit.self, from: JSONEncoder().encode(k))
        #expect(back.captionPosition == k.captionPosition)
        let old = try JSONDecoder().decode(StyleKit.self, from: Data(#"{"fonts":{},"colors":{}}"#.utf8))
        #expect(old.captionPosition == nil)
        // A kit without a position writes no key (files from before FB-Y stay byte-identical).
        let plain = try #require(String(data: JSONEncoder().encode(StyleKit()), encoding: .utf8))
        #expect(!plain.contains("captionPosition"))
    }

    @Test func unknownAlignmentFromANewerBuildFallsBack() throws {
        let p = try JSONDecoder().decode(CaptionPosition.self,
                                         from: Data(#"{"vertical":"aboveFace","horizontal":"left","offsetX":0.2}"#.utf8))
        #expect(p.vertical == .bottom && p.horizontal == .left && p.offsetX == 0.2 && p.offsetY == 0)
    }

    @Test func captionSpecRoundTripsHiddenBackground() throws {
        var s = CaptionStyleSpec(baseStyle: "pill")
        s.hidesBackground = true
        let back = try JSONDecoder().decode(CaptionStyleSpec.self, from: JSONEncoder().encode(s))
        #expect(back.hidesBackground == true)
        let plain = try #require(String(data: JSONEncoder().encode(CaptionStyleSpec(baseStyle: "pill")), encoding: .utf8))
        #expect(!plain.contains("hidesBackground"))
    }

    @Test func itemPositionRoundTripsAndStaysOutOfOldFiles() throws {
        var item = CaptionItem(lines: ["a"], range: TimeRange(start: .zero, end: Time(1, 1)))
        let plain = try #require(String(data: JSONEncoder().encode(item), encoding: .utf8))
        #expect(!plain.contains("position"))
        item.position = CaptionPosition(vertical: .top, offsetX: 0.1)
        let back = try JSONDecoder().decode(CaptionItem.self, from: JSONEncoder().encode(item))
        #expect(back.position == item.position)
    }

    @Test func setItemPositionOverridesAndResets() throws {
        let item = { (n: String, a: Int64, b: Int64) in CaptionItem(lines: [n], range: TimeRange(start: Time(a, 1), end: Time(b, 1))) }
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try tl.replaceCaptions([item("a", 0, 1), item("b", 1, 2)])
        let a = tl.captionTracks[0].items[0].id, b = tl.captionTracks[0].items[1].id
        let p = CaptionPosition(vertical: .middle, offsetY: 0.1)
        try tl.setCaptionItemPosition([a], position: p)
        let items = tl.captionTracks[0].items
        #expect(items.first { $0.id == a }?.position == p)
        #expect(items.first { $0.id == b }?.position == nil)
        try tl.setCaptionItemPosition([a], position: nil)
        #expect(tl.captionTracks[0].items.allSatisfy { $0.position == nil })
    }
}
