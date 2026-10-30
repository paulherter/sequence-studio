#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import SQCore
@testable import SQTimelineUI

@MainActor @Suite struct AttachPointDragTests {
    private func s(_ n: Int64) -> Time { Time(n, 1) }
    private let fd = Time(1, 30)

    /// V1: host a [0-20), host b [20-40). V2: attached clip [5-15) with its attach point at its start (on a).
    private func fixture() -> (Timeline, att: Clip, a: Clip, b: Clip) {
        let a = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: .zero, mediaDuration: s(60))
        let b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(20)), start: s(20), mediaDuration: s(60))
        var att = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(5), mediaDuration: s(60))
        att.attachment = ClipAttachment(host: a.id, point: .zero)
        var t = Timeline(name: "S", frameDuration: fd, tracks: [Track(kind: .video, clips: [a, b]), Track(kind: .video, clips: [att])])
        t.setEditMode(.magnetic)
        return (t, att, a, b)
    }

    private func view(_ t: Timeline) -> TimelineView {
        let v = TimelineView()
        v.frame = CGRect(x: 0, y: 0, width: 1600, height: 400)
        v.setTimeline(t)
        return v
    }

    /// A point on the thread of the attached clip of `fixture()`.
    private func threadPoint(_ v: TimelineView, _ t: Timeline, _ att: Clip) throws -> CGPoint {
        let rows = v.geometry.rows(for: t)
        let main = try #require(rows.first { $0.track == t.tracks[0].id }), top = try #require(rows.first { $0.track == t.tracks[1].id })
        let x = v.geometry.x(for: att.start)
        let span = AttachPointDrag.attachGrabSpan(clipRect: CGRect(x: x, y: top.y, width: 100, height: top.height),
                                              hostMinY: main.y, hostMaxY: main.maxY)
        return CGPoint(x: x, y: span.lowerBound + 2)
    }

    @Test func targetStaysOnTheHostAndSnapsToCutsAndPlayhead() {
        let (t, att, a, _) = fixture()
        let g = view(t).geometry
        let far = AttachPointDrag.target(x: g.x(for: s(30)), clip: att.id, in: t, geometry: g, playhead: .zero, snapping: true)
        #expect(far == a.timeline.end - fd)                                    // never on the next host
        let nearCut = AttachPointDrag.target(x: g.x(for: s(0)) + 3, clip: att.id, in: t, geometry: g, playhead: s(9), snapping: true)
        #expect(nearCut == .zero)
        let nearHead = AttachPointDrag.target(x: g.x(for: s(9)) - 2, clip: att.id, in: t, geometry: g, playhead: s(9), snapping: true)
        #expect(nearHead == s(9))
        let free = AttachPointDrag.target(x: g.x(for: s(9)) - 2, clip: att.id, in: t, geometry: g, playhead: s(9), snapping: false)
        #expect(free != s(9) && free?.snapped(to: fd) == free)
    }

    @Test func threadIsGrabbedOutsideTheClip() throws {
        let (t, att, _, _) = fixture()
        let v = view(t)
        let p = try threadPoint(v, t, att)
        #expect(AttachPointDrag.hit(at: p, in: t, geometry: v.geometry) == att.id)
        #expect(AttachPointDrag.hit(at: CGPoint(x: p.x + 30, y: p.y), in: t, geometry: v.geometry) == nil)
    }

    @Test func dragPreviewsAndCommitsOnceWithoutMovingClips() throws {
        let (t, att, _, _) = fixture()
        let v = view(t)
        var calls: [(Clip.ID, Time)] = []
        v.onSetAttachPoint = { calls.append(($0, $1)) }
        let p = try threadPoint(v, t, att)
        let to = CGPoint(x: v.geometry.x(for: s(12)), y: p.y)
        #expect(v.beginAttachDrag(at: p, modifiers: []))
        #expect(v.updateAttachDrag(to: to))
        #expect(v.timeline.tracks[1].clips[0].start == att.start)              // the clip itself stays
        #expect(v.timeline.tracks[0].clips == t.tracks[0].clips)               // no gap, no ripple
        #expect(v.endAttachDrag(at: to))
        #expect(calls.count == 1 && calls[0].0 == att.id)
        #expect(calls[0].1.snapped(to: fd) == calls[0].1 && abs(Double(calls[0].1.value) / Double(calls[0].1.timescale) - 12) < 0.2)
        #expect(v.timeline == t)                                               // the host's edit brings the new state
    }

    @Test func modifiersKeepTheirOwnMeaning() throws {
        let (t, att, _, _) = fixture()
        let v = view(t)
        v.onSetAttachPoint = { _, _ in }
        let p = try threadPoint(v, t, att)
        #expect(!v.beginAttachDrag(at: p, modifiers: [.command, .option]))
        #expect(!v.beginAttachDrag(at: p, modifiers: [.shift]))
    }
}
