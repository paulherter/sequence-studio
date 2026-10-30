import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
@testable import SQDrawTimeline

@MainActor @Suite struct TimelineKeyParityTests {
    func panel() -> (TimelinePanel, EditorSession) {
        let fd = Time(1, 25)
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 100), start: .zero)
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip])])]))
        var p = TimelinePanel()
        p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
        p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: s.playhead, selectedTransition: nil, labels: LabelResolver())
        return (p, s)
    }

    @Test func escapeGoesBackToTheSelectionTool() {
        var (p, _) = panel()
        _ = p.key(.character("b"), modifiers: [])
        #expect(p.toolState.tool != .selection)
        #expect(p.key(.escape, modifiers: []) == [])
        #expect(p.toolState.tool == .selection)
        #expect(p.key(.escape, modifiers: []) == nil, "the second Esc is the host's")
    }

    @Test func aHeldDeleteIsSwallowed() {
        var (p, _) = panel()
        let out = HostKeyRepeat.shared.with(true) { p.key(.backspace, modifiers: []) }
        #expect(out == [])
    }

    final class Ticker: @unchecked Sendable { var t = 100.0 }

    @Test func aHeldToolKeyIsTemporary() {
        var (p, _) = panel()
        let ticker = Ticker()
        p.clock = { ticker.t }
        _ = p.key(.character("b"), modifiers: [])
        #expect(p.toolState.tool == .rippleEdit)
        ticker.t += 0.6
        _ = p.keyUp(.character("b"))
        #expect(p.toolState.tool == .selection, "a long hold returns to the tool from before")
    }

    @Test func aTappedToolKeyStays() {
        var (p, _) = panel()
        let ticker = Ticker()
        p.clock = { ticker.t }
        _ = p.key(.character("c"), modifiers: [])
        ticker.t += 0.1
        _ = p.keyUp(.character("c"))
        #expect(p.toolState.tool == .razor)
    }

    @Test func aRepeatOfTheToolKeyDoesNotRestartTheHold() {
        var (p, _) = panel()
        let ticker = Ticker()
        p.clock = { ticker.t }
        _ = p.key(.character("b"), modifiers: [])
        ticker.t += 0.5
        _ = HostKeyRepeat.shared.with(true) { p.key(.character("b"), modifiers: []) }
        _ = p.keyUp(.character("b"))
        #expect(p.toolState.tool == .selection)
    }

    @Test func losingTheWindowEndsAToolHold() {
        var (p, _) = panel()
        let ticker = Ticker()
        p.clock = { ticker.t }
        _ = p.key(.character("h"), modifiers: [])
        ticker.t += 1
        _ = p.releaseHeldKeys()
        #expect(p.toolState.tool == .selection)
        _ = p.keyUp(.character("h"))
        #expect(p.toolState.tool == .selection, "the late key up changes nothing")
    }

    @Test func escapeEndsTheHoldForGood() {
        var (p, _) = panel()
        let ticker = Ticker()
        p.clock = { ticker.t }
        _ = p.key(.character("b"), modifiers: [])
        _ = p.key(.escape, modifiers: [])
        _ = p.key(.character("c"), modifiers: [])
        ticker.t += 1
        _ = p.keyUp(.character("b"))
        #expect(p.toolState.tool == .razor, "the stale hold of B must not undo the later tool")
    }
}
