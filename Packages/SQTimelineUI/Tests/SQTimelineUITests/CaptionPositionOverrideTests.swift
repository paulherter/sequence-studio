#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
import SQCore
import SQText
@testable import SQTimelineUI

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    s.replaceCaptions([
        CaptionItem(lines: ["a"], range: TimeRange(start: .zero, end: Time(1, 1)), styleRef: "default"),
        CaptionItem(lines: ["b"], range: TimeRange(start: Time(1, 1), end: Time(2, 1)), styleRef: "default"),
    ])
    return s
}

/// Per-caption position: dragged in the Program monitor, nudged in the Style tab, reset to the kit position.
@MainActor @Suite(.serialized) struct CaptionPositionOverrideTests {
    @Test func dragMovesByTheDeltaAsFractionOfTheCanvas() {
        let r = CaptionDrag.moved(start: .default, textRect: CGRect(x: -300, y: 300, width: 600, height: 80),
                                  delta: Vec2(192, -108), canvas: CGSize(width: 1920, height: 1080), threshold: 0)
        #expect(abs(r.position.offsetX - 0.1) < 1e-9 && abs(r.position.offsetY + 0.1) < 1e-9)
        #expect(r.position.vertical == .bottom && r.position.horizontal == .center)
    }

    @Test func dragSnapsToCentreAndSafeZones() {
        let canvas = CGSize(width: 1920, height: 1080)
        let r = CaptionDrag.moved(start: .default, textRect: CGRect(x: -300, y: 300, width: 600, height: 80),
                                  delta: Vec2(5, 0), canvas: canvas, threshold: 8)
        #expect(r.position.offsetX == 0)
        #expect(r.guides.verticalLines.contains(0))
        // Title safe bottom edge: 540 - 108 = 432. Block bottom at 380, moved 50 down -> snaps to 432 (dy 52).
        let s = CaptionDrag.moved(start: .default, textRect: CGRect(x: -300, y: 300, width: 600, height: 80),
                                  delta: Vec2(0, 50), canvas: canvas, threshold: 8)
        #expect(abs(s.position.offsetY - 52 / 1080) < 1e-9)
        #expect(s.guides.horizontalLines.contains { abs($0 - 432) < 1e-6 })
    }

    @Test func noSnapWhenThresholdIsZero() {
        let r = CaptionDrag.moved(start: .default, textRect: CGRect(x: -300, y: 300, width: 600, height: 80),
                                  delta: Vec2(5, 0), canvas: CGSize(width: 1920, height: 1080), threshold: 0)
        #expect(abs(r.position.offsetX - 5 / 1920) < 1e-9 && r.guides.verticalLines.isEmpty)
    }

    @Test func sessionOverrideIsOneUndoStepAndResets() throws {
        let s = makeSession()
        let a = try #require(s.captionItems.first?.id)
        s.setCaptionItemPosition([a], CaptionPosition(vertical: .top, offsetX: 0.1), continuesGesture: false)
        s.setCaptionItemPosition([a], CaptionPosition(vertical: .top, offsetX: 0.2), continuesGesture: true)
        #expect(s.captionItem(a)?.position?.offsetX == 0.2)
        #expect(s.captionItems[1].position == nil)
        s.undo()   // the whole drag
        #expect(s.captionItem(a)?.position == nil)
        s.redo()
        s.resetCaptionPositions([a])
        #expect(s.captionItem(a)?.position == nil)
    }

    @Test func effectivePositionFollowsKitUntilOverridden() throws {
        let s = makeSession()
        s.setCaptionPosition(CaptionPosition(vertical: .middle))
        let a = try #require(s.captionItems.first)
        #expect(s.effectiveCaptionPosition(a).vertical == .middle)
        s.setCaptionItemPosition([a.id], CaptionPosition(vertical: .top), continuesGesture: false)
        #expect(s.effectiveCaptionPosition(try #require(s.captionItem(a.id))).vertical == .top)
        #expect(s.effectiveCaptionPosition(s.captionItems[1]).vertical == .middle)
    }
}
