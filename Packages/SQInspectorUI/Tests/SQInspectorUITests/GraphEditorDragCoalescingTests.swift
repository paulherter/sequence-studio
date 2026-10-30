import AppKit
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

/// A key drag in the Graph Editor commits to the model at most once per display frame; the last pointer position is
/// still committed on mouse-up and the drag stays one undo step.
@MainActor @Suite struct GraphEditorDragCoalescingTests {
    private func event(_ type: NSEvent.EventType, _ v: GraphEditorView, _ p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: v.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func manyDragEventsInOneFrameCommitFewTimesAndEndOnTheLastPosition() {
        let o0 = UUID(), o1 = UUID()
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        clip.animation.opacity.track = KeyframeTrack(keys: [Keyframe(id: o0, time: Time(0, 1), value: 0),
                                                            Keyframe(id: o1, time: Time(4, 1), value: 1)])
        let m = EffectControlsModel()
        var commits = 0
        m.onEdit = { _, _, _ in commits += 1 }
        m.setClip(clip)
        m.graphShowAll = true
        m.graphSnap = false
        let v = GraphEditorView(model: m)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = v
        v.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
        let g = v.geometry
        let c = g.curve(EffectProperty.opacity.id)!
        let start = g.keyPoint(c, c.curve.keys[1])
        v.mouseDown(with: event(.leftMouseDown, v, start))
        let onePoint = g.lane.pointsPerSecond      // one second to the left
        let steps = 20
        for i in 1...steps {
            v.mouseDragged(with: event(.leftMouseDragged, v, CGPoint(x: start.x - onePoint * CGFloat(i) / CGFloat(steps), y: start.y)))
        }
        v.mouseUp(with: event(.leftMouseUp, v, CGPoint(x: start.x - onePoint, y: start.y)))
        #expect(commits < steps / 2, "\(commits) commits for \(steps) events")
        #expect(m.clip!.animation.opacity.track.key(id: o1)?.time == Time(3, 1))
    }

    @Test func escapeDuringAMarqueeRestoresTheSelection() {
        let o0 = UUID(), o1 = UUID()
        var clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        clip.animation.opacity.track = KeyframeTrack(keys: [Keyframe(id: o0, time: Time(0, 1), value: 0),
                                                            Keyframe(id: o1, time: Time(4, 1), value: 1)])
        let m = EffectControlsModel()
        m.setClip(clip)
        m.graphShowAll = true
        let v = GraphEditorView(model: m)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = v
        v.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
        let g = v.geometry
        let c = g.curve(EffectProperty.opacity.id)!
        let k0 = g.keyPoint(c, c.curve.keys[0]), k1 = g.keyPoint(c, c.curve.keys[1])
        let before = Set([SummaryMember(property: EffectProperty.opacity.id, keyID: o0)])
        m.select(Array(before), extend: false)
        let origin = CGPoint(x: k1.x + 30, y: min(k0.y, k1.y) - 20)
        v.mouseDown(with: event(.leftMouseDown, v, origin))
        v.mouseDragged(with: event(.leftMouseDragged, v, CGPoint(x: k1.x - 20, y: max(k0.y, k1.y) + 20)))
        #expect(m.selection.contains(SummaryMember(property: EffectProperty.opacity.id, keyID: o1)))
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        v.keyDown(with: esc)
        v.mouseUp(with: event(.leftMouseUp, v, origin))
        #expect(m.selection == before)
    }
}
