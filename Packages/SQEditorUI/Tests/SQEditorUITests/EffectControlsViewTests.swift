import AppKit
import Testing
import SQCore
@testable import SQEditorUI

@MainActor @Suite struct EffectControlsViewTests {
    func setup(kind: TrackKind = .video) -> (EffectControlsModel, EffectControlsView) {
        let m = EffectControlsModel()
        m.setClip(Clip(name: "c", media: UUID(), kind: kind,
                       source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1)))
        m.playhead = Time(5, 1)
        let v = EffectControlsView(model: m)
        v.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        v.layoutSubtreeIfNeeded()
        return (m, v)
    }

    func scrubFields(_ v: NSView) -> [ScrubField] {
        var out: [ScrubField] = []
        func walk(_ n: NSView) { for s in n.subviews { if let f = s as? ScrubField { out.append(f) }; walk(s) } }
        walk(v); return out
    }

    @Test func videoClipShowsMotionAndOpacityFields() {
        let (_, v) = setup()
        // position 2, scale 1, rotation 1, anchor 2, opacity 1 (effects only once applied)
        #expect(scrubFields(v).count == 7)
    }

    @Test func audioClipShowsOnlyVolume() {
        let (_, v) = setup(kind: .audio)
        #expect(scrubFields(v).count == 1)
    }

    @Test func fieldEditGoesThroughModelAsOneGesture() {
        let (m, v) = setup()
        var log: [(String, Bool)] = []
        m.onEdit = { _, n, c in log.append((n, c)) }
        let rotation = scrubFields(v)[3]        // position x, y, scale, rotation ...
        #expect(rotation.accessibilityLabel() == "Rotation")
        rotation.onBegin?(); rotation.onChange?(10); rotation.onChange?(20); rotation.onEnd?(20)
        #expect(m.clip!.animation.rotation.value == 20)
        #expect(log.map(\.1) == [false, true])
    }

    @Test func diamondTogglesStopwatchWithConfirmation() {
        let (m, v) = setup()
        let opacity = scrubFields(v)[6]
        #expect(opacity.accessibilityLabel() == "Opacity")
        opacity.onKeyframeToggle?()
        #expect(m.isAnimated(.opacity))
        var asked = 0
        v.confirmRemoval = { _ in asked += 1; return false }
        opacity.onKeyframeToggle?()
        #expect(asked == 1 && m.isAnimated(.opacity))
        v.confirmRemoval = { _ in asked += 1; return true }
        opacity.onKeyframeToggle?()
        #expect(!m.isAnimated(.opacity))
    }

    @Test func collapsedSectionAddsNoRowsAndExpandAddsGraph() async {
        let (m, v) = setup()
        m.collapsedSections = [.motion]
        try? await Task.sleep(for: .milliseconds(50))    // observation re-arms on the main actor
        v.layoutSubtreeIfNeeded()
        #expect(scrubFields(v).count == 1)
        m.collapsedSections = []; m.expanded = [.opacity]
        try? await Task.sleep(for: .milliseconds(50))
        var graphs = 0
        func walk(_ n: NSView) { for s in n.subviews { if s is KeyframeGraphView { graphs += 1 }; walk(s) } }
        walk(v)
        #expect(graphs == 1)
    }

    @Test func laneHitTestFindsKeys() async {
        let (m, v) = setup()
        m.toggleStopwatch(.opacity)
        try? await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        let lanes = v.firstSubview(of: EffectKeyframeLanesView.self)!
        let row = lanes.rows.first { $0.kind == .property(.opacity) }!
        let x = lanes.geometry.x(for: .zero)
        if case .key(.opacity, _, _) = lanes.hit(at: CGPoint(x: x, y: row.y + 10)) {} else { Issue.record("no key hit") }
        #expect(lanes.hit(at: CGPoint(x: x + 50, y: row.y + 10)) == .none)
    }

    @Test func collapsedSectionHitsSummaryKey() async {
        let (m, v) = setup()
        m.toggleStopwatch(.rotation)
        m.collapsedSections = [.motion]
        try? await Task.sleep(for: .milliseconds(50))
        v.layoutSubtreeIfNeeded()
        let lanes = v.firstSubview(of: EffectKeyframeLanesView.self)!
        let row = lanes.rows.first { $0.kind == .section(.motion) }!
        let x = lanes.geometry.x(for: .zero)
        #expect(lanes.hit(at: CGPoint(x: x, y: row.y + 10)) == .summary(.motion, .zero))
    }
}

extension NSView {
    func firstSubview<T: NSView>(of t: T.Type) -> T? {
        for s in subviews { if let m = s as? T { return m }; if let m = s.firstSubview(of: t) { return m } }
        return nil
    }
}
