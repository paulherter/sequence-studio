import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

/// V1: two 50-frame clips butted at frame 50 (each with 20 frames of spare footage), so the edit can roll.
@MainActor private func setup() -> (EditorSession, TrimModeModel, TrimPoint) {
    func clip(_ start: Int64) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: fd * 20, duration: fd * 50), start: fd * start)
    }
    let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(0), clip(50)])])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    let m = TrimModeModel(session: s)
    let tr = s.activeTimeline!.tracks[0]
    let p = TrimPoint(track: tr.id, outgoing: tr.clips[0].id, incoming: tr.clips[1].id, time: fd * 50)
    return (s, m, p)
}

private func press(_ bar: inout TrimBar, _ p: CGPoint) -> [TrimBarAction] {
    _ = bar.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: []))
    return bar.handle(.mouseUp(x: Float(p.x), y: Float(p.y))) ?? []
}

@MainActor @Suite struct TrimBarTests {
    @Test func buttonsFollowTheMacRowAndDriveTheModel() {
        let (s, m, p) = setup()
        m.enter(p, side: .roll)
        var bar = TrimBar()
        bar.layout(in: CGRect(x: 0, y: 300, width: 800, height: TrimBar.height), scale: 1)
        bar.update(from: m)
        let rects = bar.rects()
        #expect(TrimBar.steps == TrimModeModel.steps)
        // Side switch left, four steps centered, Done right.
        #expect(rects.map(\.0) == [.side(.outgoing), .side(.incoming), .side(.roll), .step(-5), .step(-1), .step(1), .step(5), .done])
        let stepRow = rects.filter { if case .step = $0.0 { true } else { false } }.map(\.1)
        #expect(abs((stepRow.first!.minX + stepRow.last!.maxX) / 2 - 400) <= 1)
        #expect(rects.last!.1.maxX <= 800 && rects.first!.1.minX >= 0)

        let plusOne = rects.first { $0.0 == .step(1) }!.1
        let a = press(&bar, CGPoint(x: plusOne.midX, y: plusOne.midY))
        #expect(a == [.step(1)])
        m.step(frames: 1)
        #expect(s.activeTimeline!.tracks[0].clips[0].duration == fd * 51)   // the roll moved the edit one frame
        bar.update(from: m)
        #expect(!bar.note.isEmpty)

        let before = rects.first { $0.0 == .side(.outgoing) }!.1
        #expect(press(&bar, CGPoint(x: before.midX, y: before.midY)) == [.side(.outgoing)])
        let done = rects.last!.1
        #expect(press(&bar, CGPoint(x: done.midX, y: done.midY)) == [.done])
        #expect(bar.handle(.mouseDown(x: 5, y: 5, modifiers: [])) == nil)   // above the bar: not the bar's

        var c = Canvas(list: DrawList(width: 800, height: 400), atlas: nil, scale: 1)
        bar.draw(&c)
        #expect(!c.list.quads.isEmpty)
    }

    @Test func aSideTheEditLacksIsDimmedAndEdgesFollowTheSide() {
        let (_, m, p) = setup()
        let gapEdge = TrimPoint(track: p.track, outgoing: p.outgoing, incoming: nil, time: p.time)
        m.enter(gapEdge)
        var bar = TrimBar()
        bar.layout(in: CGRect(x: 0, y: 0, width: 800, height: TrimBar.height), scale: 2)
        bar.update(from: m)
        #expect(bar.sides == [.outgoing])
        let both = bar.rects().first { $0.0 == .side(.roll) }!.1
        #expect(press(&bar, CGPoint(x: both.midX * 2, y: both.midY * 2)).isEmpty)   // pixels in, dimmed: nothing

        #expect(TrimBar.edges(for: p, side: .roll) == EdgeSelection(edges: [EdgeRef(clip: p.outgoing!, edge: .tail),
                                                                           EdgeRef(clip: p.incoming!, edge: .head)], ripple: false))
        #expect(TrimBar.edges(for: p, side: .incoming)?.ripple == true)
        #expect(TrimBar.edges(for: gapEdge, side: .incoming) == nil)
    }
}

@Suite struct TimelineEditorFormsTests {
    @Test func matteColorReadsHexAndDurationClamps() {
        #expect(TimelineEditorForms.matteColor(hex: "#28282e") == ColorMatteColor.default)
        #expect(TimelineEditorForms.matteColor(hex: " F0a ") == ColorMatteColor(r: 0xFF, g: 0x00, b: 0xAA))
        #expect(TimelineEditorForms.matteColor(hex: "#12345") == nil)
        #expect(TimelineEditorForms.matteColor(hex: "zzzzzz") == nil)
        #expect(TimelineEditorForms.hex(.default) == "#28282E")
        #expect(TimelineEditorForms.matteDuration(seconds: 5) == Time(5, 1))
        #expect(TimelineEditorForms.matteDuration(seconds: 0) == Time(100, 1000))
        #expect(TimelineEditorForms.matteDuration(seconds: 1e9) == Time(3600, 1))
    }
}
