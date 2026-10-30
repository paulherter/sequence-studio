import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQLibrary
@testable import SQDrawShell

@MainActor
@Suite struct ShellCardBrowserTests {
    func items() -> [CardCandidate] {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        return [CardCandidate(url: URL(fileURLWithPath: "/c/B.MP4"), kind: .video, size: 300, modified: day),
                CardCandidate(url: URL(fileURLWithPath: "/c/A.MP4"), kind: .video, size: 100, modified: day.addingTimeInterval(60)),
                CardCandidate(url: URL(fileURLWithPath: "/c/C.MP4"), kind: .video, size: 200, modified: day.addingTimeInterval(120)),
                CardCandidate(url: URL(fileURLWithPath: "/c/P.JPG"), kind: .photo, size: 10, modified: day)]
    }

    func laidOut() -> ShellCardBrowser {
        let b = ShellCardBrowser(items: items())
        b.layout(CGRect(x: 0, y: 0, width: 860, height: b.height(width: 860)), measure: TextMeasure(atlas: nil, scale: 1))
        return b
    }

    @Test func boardMatchesTheMacLayout() {
        let b = laidOut()
        #expect(b.height(width: 860) == ShellDialog.M.lBodyHeight)
        #expect(b.toolbarFrame.height == 36)                                       // 4 above, 22, 10 below
        #expect(b.kindFrames[0].1.minX == 16 && b.kindFrames[0].1.minY == 4 && b.kindFrames[0].1.height == 22)
        #expect(b.layoutFrames[1].1.maxX == CGFloat(844))                              // toggles at the right edge
        #expect(b.sortFrame.maxX == b.layoutFrames[0].1.minX - 12 && b.sortFrame.width == ceil(CardSort.allCases.map { TextMeasure(atlas: nil, scale: 1).width($0.title, size: ShellCardBrowser.M.font) }.max() ?? 0) + 32)   // widest title + 32, like SQPopup
        #expect(b.listFrame.minY == 37 && b.previewFrame.width == 301 && b.previewFrame.maxX == 860)
    }

    @Test func showsTheKindInTheChosenOrder() {
        let b = laidOut()
        #expect(b.kind == .video)
        #expect(b.visible.map(\.name) == ["C.MP4", "A.MP4", "B.MP4"])     // newest first
        b.setSort(.name)
        #expect(b.visible.map(\.name) == ["A.MP4", "B.MP4", "C.MP4"])
        b.setSort(.size)
        #expect(b.visible.map(\.name) == ["B.MP4", "C.MP4", "A.MP4"])
        #expect(b.kindTitle(.video) == "Videos (3)" && b.kindTitle(.photo) == "Photos (1)")
        #expect(b.statusText == "0 selected")
    }

    @Test func clicksOnTilesSelectRangesTogglesAndPreview() {
        let b = laidOut()
        let tile = { (i: Int) in b.cellFrame(i) }
        func press(_ p: CGPoint, _ m: InputModifiers = []) {
            _ = b.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: m), scale: 1)
        }
        press(CGPoint(x: tile(0).midX, y: tile(0).midY))
        #expect(b.selected.map(\.name) == ["C.MP4"] && b.preview?.name == "C.MP4")
        press(CGPoint(x: tile(2).midX, y: tile(2).midY), .shift)
        #expect(b.selected.count == 3 && b.preview?.name == "B.MP4")
        press(CGPoint(x: b.checkFrame(tile(1)).midX, y: b.checkFrame(tile(1)).midY))     // the checkbox toggles one
        #expect(b.selected.map(\.name) == ["C.MP4", "B.MP4"])
        #expect(b.statusText == "2 selected")
        // The kind segment switches and drops the other kind's ticks and preview.
        let photos = b.kindFrames.first { $0.0 == .photo }!.1
        press(CGPoint(x: photos.midX, y: photos.midY))
        #expect(b.kind == .photo && b.selected.isEmpty && b.preview == nil)
        #expect(b.handle(.keyDown(.character("a"), modifiers: .command), scale: 1))
        #expect(b.selected.map(\.name) == ["P.JPG"])
    }

    @Test func listLayoutUsesRowsAndTheSortPopupOffersEveryOrder() {
        let b = laidOut()
        let list = b.layoutFrames.first { $0.0 == .list }!.1
        _ = b.handle(.mouseDown(x: Float(list.midX), y: Float(list.midY), modifiers: []), scale: 1)
        #expect(b.layout == .list)
        #expect(b.cellFrame(1).minY - b.cellFrame(0).minY == 24)
        var offered: [String] = []
        b.openPopup = { items, _ in offered = items.map(\.title); items[2].action?() }
        _ = b.handle(.mouseDown(x: Float(b.sortFrame.midX), y: Float(b.sortFrame.midY), modifiers: []), scale: 1)
        #expect(offered == CardSort.allCases.map(\.title))
        #expect(b.sort == .name)
    }

    @Test func drawsTilesWithPostersAndTheYellowPreviewOutline() {
        let b = laidOut()
        var asked: [String] = []
        b.poster = { asked.append($0.name); return ProjectPoster(slot: 2, pixelSize: CGSize(width: 160, height: 90)) }
        b.click(b.visibleIDs[0])
        var c = Canvas(width: 1000, height: 800, atlas: nil, scale: 1)
        b.draw(&c, theme: DrawTheme(scale: 1))
        #expect(Set(asked) == ["C.MP4", "A.MP4", "B.MP4"])
        #expect(c.list.quads.contains { $0.kind == DrawQuad.Kind.image.rawValue && $0.pad == 2 })
    }
}
