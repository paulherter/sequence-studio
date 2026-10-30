import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// The shared-toolkit Effect Controls with keyframe lanes and ruler (Windows): the Mac lane gestures on the same model.
@MainActor @Suite struct EffectKeyframeLanesDrawTests {
    private func view() -> EffectControlsDrawView {
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let m = EffectControlsModel()
        m.setClip(c)
        let v = EffectControlsDrawView(model: m)
        v.persistLabelWidth = { _ in }
        v.size = CGSize(width: 900, height: 1200)
        v.relayout()
        return v
    }

    /// Animates Opacity with the row's ring (one key at the playhead) and returns the key's point in panel coordinates.
    private func animateOpacity(_ v: EffectControlsDrawView) throws -> CGPoint {
        let r = try #require(v.rowsPanel.rows.first { $0.kind == .property(.opacity) })
        let ring = CGPoint(x: ControlsGrid.toggleMidX, y: v.top + r.y + r.height / 2)
        v.mouseDown(at: ring, clickCount: 1, modifiers: []); v.mouseUp(at: ring)
        #expect(v.model.keys(.opacity).count == 1)
        v.relayout()
        let x = v.lanes.geometry.x(for: v.model.localPlayhead)
        return CGPoint(x: v.laneX + x, y: v.top + r.y + r.height / 2)
    }

    @Test func layoutIsTheMacSplit() {
        let v = view()
        #expect(v.laneX == EffectControlsSplit.clamp(v.labelWidth, total: 900))
        #expect(v.rowsPanel.size.width == v.laneX)
        #expect(v.lanes.size.width == 900 - v.laneX)
        #expect(v.lanes.rows == v.rowsPanel.rows)
        #expect(v.part(at: CGPoint(x: v.laneX + 50, y: ControlsMetrics.clipLine + 4)) == .ruler)
        #expect(v.part(at: CGPoint(x: v.laneX, y: 400)) == .divider)
    }

    @Test func clickSelectsAKeyAndDragMovesItAsOneStep() throws {
        let v = view(), m = v.model
        let key = try animateOpacity(v)
        var names: [String] = []
        m.onEdit = { _, n, _ in names.append(n) }
        #expect(m.selection.isEmpty)
        v.mouseDown(at: key, clickCount: 1, modifiers: [])
        #expect(m.selectedKeyIDs(.opacity).count == 1)
        let to = CGPoint(x: key.x + 60, y: key.y)
        v.mouseDragged(to: CGPoint(x: key.x + 30, y: key.y))
        v.mouseDragged(to: to)
        v.mouseUp(at: to)
        let moved = try #require(m.keys(.opacity).first)
        #expect(moved.time > (m.clip?.start ?? .zero))
        #expect(Set(names).count == 1)
    }

    @Test func marqueeOnEmptyLaneSelectsTheKeysUnderIt() throws {
        let v = view(), m = v.model
        let key = try animateOpacity(v)
        m.clearSelection()
        let from = CGPoint(x: key.x + 30, y: key.y - 8), to = CGPoint(x: v.laneX + 1, y: key.y + 8)
        v.mouseDown(at: from, clickCount: 1, modifiers: [])
        #expect(m.selection.isEmpty)
        v.mouseDragged(to: CGPoint(x: key.x + 10, y: key.y))
        v.mouseDragged(to: to)
        #expect(v.lanes.marquee != nil)
        #expect(m.selectedKeyIDs(.opacity).count == 1)
        v.mouseUp(at: to)
        #expect(v.lanes.marquee == nil)
    }

    @Test func rightClickOnAKeyOffersTheMacMenuAndDeleteRemovesIt() throws {
        let v = view(), m = v.model
        let key = try animateOpacity(v)
        var shown: [SQMenuItem] = []
        v.onMenu = { items, _ in shown = items }
        v.mouseDown(at: key, clickCount: 1, modifiers: .secondary); v.mouseUp(at: key)
        let titles = shown.map(\.title)
        #expect(titles.contains("Temporal Interpolation") && titles.contains("Delete") && titles.contains("Copy"))
        #expect(!titles.contains("Scale Time\u{2026}"))      // no prompt host: the dialog tools stay out
        v.onPrompt = { _, done in done(["200"]) }
        v.mouseDown(at: key, clickCount: 1, modifiers: .secondary); v.mouseUp(at: key)
        #expect(shown.map(\.title).contains("Scale Time\u{2026}"))
        #expect(v.key(.delete, modifiers: []))
        #expect(m.keys(.opacity).isEmpty)
    }

    @Test func rulerPressScrubsThePlayhead() {
        let v = view(), m = v.model
        var scrubbed: [Time] = [], began = 0, ended = 0
        m.onScrubBegan = { began += 1 }
        m.onScrub = { scrubbed.append($0) }
        m.onSeek = { scrubbed.append($0) }
        m.onScrubEnded = { ended += 1 }
        let p = CGPoint(x: v.laneX + v.lanes.size.width / 2, y: ControlsMetrics.clipLine + 6)
        v.mouseDown(at: p, clickCount: 1, modifiers: [])
        v.mouseDragged(to: CGPoint(x: p.x + 40, y: p.y))
        v.mouseUp(at: CGPoint(x: p.x + 40, y: p.y))
        #expect(began == 1 && ended == 1)
        #expect(!scrubbed.isEmpty)
    }

    @Test func dividerDragMovesTheSplit() {
        let v = view()
        let x0 = v.laneX
        v.mouseDown(at: CGPoint(x: x0, y: 300), clickCount: 1, modifiers: [])
        v.mouseDragged(to: CGPoint(x: x0 + 40, y: 300))
        v.mouseUp(at: CGPoint(x: x0 + 40, y: 300))
        #expect(v.laneX == EffectControlsSplit.clamp(x0 + 40, total: 900))
        #expect(v.rowsPanel.size.width == v.laneX)
    }

    @Test func drawsHeaderRowsRulerAndLanes() throws {
        let v = view()
        _ = try animateOpacity(v)
        var c = Canvas(width: 900, height: 1200, atlas: nil, scale: 1)
        v.draw(&c)
        let img = SoftwareRenderer.render(c.list, width: 900, height: 400, clear: .black, atlas: nil)
        #expect(img.pixels[(100 * 900 + Int(v.laneX) + 100) * 4 + 3] == 255)     // the lanes fill
    }
}
