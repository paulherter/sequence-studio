import CoreGraphics
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 24)

@Suite struct TimelineCursorMapTests {
    let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 48), start: fd * 10)
    var timeline: Timeline { Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)]) }
    let content = CGRect(x: 162, y: 22, width: 1000, height: 300)

    private func regions(_ tool: TimelineTool, pointsPerFrame: Double = 4) -> [TimelineCursorMap.Region] {
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: pointsPerFrame)
        return TimelineCursorMap.regions(timeline: timeline, geometry: g, tool: tool, content: content)
    }

    @Test func selectionShowsTrimCursorsOnBothEdges() {
        let r = regions(.selection)
        #expect(r.map(\.kind) == [.trimIn, .trimOut])
        #expect(r[0].rect.width == 6 && r[1].rect.width == 6)
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)
        #expect(r[0].rect.minX == g.x(for: fd * 10))
        #expect(r[1].rect.maxX == g.x(for: fd * 58))
    }

    @Test func regionsAgreeWithHitTestAtManyZooms() {
        for ppf in [0.05, 0.3, 1, 4, 40, 300] {
            let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: ppf)
            let rows = g.rows(for: timeline)
            let y = rows[0].y + rows[0].height / 2
            let regions = TimelineCursorMap.regions(timeline: timeline, geometry: g, tool: .selection, content: content)
            for x in stride(from: CGFloat(170), to: 1100, by: 1.5) {
                let p = CGPoint(x: x, y: y)
                let hit = g.hitTest(p, in: timeline)
                let kind = regions.first { $0.rect.contains(p) }?.kind
                switch hit {
                case .clip(_, .head): #expect(kind == .trimIn, "x \(x) ppf \(ppf)")
                case .clip(_, .tail): #expect(kind == .trimOut, "x \(x) ppf \(ppf)")
                default: #expect(kind == nil, "x \(x) ppf \(ppf)")
                }
            }
        }
    }

    @Test func rippleRollSlipSlideRazorHand() {
        #expect(regions(.rippleEdit).map(\.kind) == [.rippleIn, .rippleOut])
        #expect(regions(.rollEdit).map(\.kind) == [.roll])
        #expect(regions(.slip).map(\.kind) == [.slip])
        #expect(regions(.slide).map(\.kind) == [.slide])
        #expect(regions(.razor).map(\.kind) == [.razor])
        #expect(regions(.hand).map(\.kind) == [.hand])
        #expect(regions(.trackSelectForward).isEmpty)
    }

    @Test func regionsDoNotOverlapAndStayInsideContent() {
        for tool in TimelineTool.allCases {
            let r = regions(tool, pointsPerFrame: 0.5)
            for (i, a) in r.enumerated() {
                #expect(content.contains(a.rect))
                for b in r[(i + 1)...] { #expect(a.rect.intersection(b.rect).width <= 0.001 || a.rect.intersection(b.rect).height <= 0.001) }
            }
        }
    }

    @Test func offscreenClipsProduceNothing() {
        var g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)
        g.scrollX = 5000
        #expect(TimelineCursorMap.regions(timeline: timeline, geometry: g, tool: .selection, content: content).isEmpty)
    }
}
