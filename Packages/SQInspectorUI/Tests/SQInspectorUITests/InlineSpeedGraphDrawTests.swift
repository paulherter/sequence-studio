import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// The opened row's curve on the shared toolkit (Windows): the Mac `InlineSpeedGraphView` gestures through the panel.
@MainActor @Suite struct InlineSpeedGraphDrawTests {
    /// Opacity keyed at 0 s and 2 s of a 10 s clip, its row opened, in a 900 pt panel.
    private func view() throws -> (EffectControlsDrawView, CGRect) {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1)))
        m.playhead = Time(5, 1)
        m.toggleStopwatch(.opacity)
        m.playhead = Time(7, 1)
        m.setValue(.opacity, to: 0.5)
        m.toggleOpen(.opacity)
        let v = EffectControlsDrawView(model: m)
        v.persistLabelWidth = { _ in }
        v.size = CGSize(width: 900, height: 1200)
        v.relayout()
        let r = try #require(v.rowsPanel.rows.first { $0.kind == .graph(.opacity) })
        return (v, CGRect(x: v.laneX, y: v.top + r.y, width: 900 - v.laneX, height: r.height))
    }

    @Test func openedRowShowsTheCurveOverTheLanes() throws {
        let (v, f) = try view()
        #expect(v.part(at: CGPoint(x: f.midX, y: f.midY)) == .graph(.opacity))
        #expect(v.part(at: CGPoint(x: f.midX, y: f.minY - 4)) == .lanes)
        var c = Canvas(width: 900, height: 1200, atlas: nil, scale: 1)
        v.draw(&c)
        let img = SoftwareRenderer.render(c.list, width: 900, height: 1200, clear: .black, atlas: nil)
        #expect(img.pixels[(Int(f.midY) * 900 + Int(f.midX)) * 4 + 3] == 255)
    }

    @Test func rightClickOffersTheCurvePresetsAndTheKeyItems() throws {
        let (v, f) = try view()
        var shown: [SQMenuItem] = []
        v.onMenu = { items, _ in shown = items }
        v.mouseDown(at: CGPoint(x: f.maxX - 4, y: f.midY), clickCount: 1, modifiers: .secondary)
        let titles = shown.map(\.title)
        #expect(Array(titles.prefix(5)) == ["Steady", "Smooth", "Smooth In", "Smooth Out", "Hold"])
        #expect(titles.contains("Delete"))
        let smooth = try #require(shown.first { $0.title == "Smooth" })
        v.model.setSelection(for: .opacity, ids: Set(v.model.track(.opacity)!.keyIDs))
        smooth.action?()
        #expect(v.model.speedChip(for: .opacity) == .smooth)
    }

    @Test func handleDragIsOneGestureAndSetsTheReach() throws {
        let (v, f) = try view()
        let m = v.model
        m.applySpeedChip(.smooth, for: .opacity)
        let g = v.graph(.opacity)
        g.size = f.size
        let seg = m.speedSegments(.opacity)[0]
        let end = g.geometry.handleEnd(seg, side: .out)
        var gestures = 0
        let began = m.onEdit
        m.onEdit = { c, n, k in gestures += 1; began?(c, n, k) }
        let start = CGPoint(x: f.minX + end.x, y: f.minY + end.y)
        v.mouseDown(at: start, clickCount: 1, modifiers: [])
        v.mouseDragged(to: CGPoint(x: start.x + 15, y: start.y))
        v.mouseDragged(to: CGPoint(x: start.x + 30, y: start.y))
        v.mouseUp(at: CGPoint(x: start.x + 30, y: start.y))
        #expect(m.speedValues(for: .opacity)!.reachOut > 1.0 / 3)
        #expect(gestures >= 1)
    }

    @Test func marqueeFromTheCurveSelectsTheKeys() throws {
        let (v, f) = try view()
        let m = v.model
        m.clearSelection()
        let from = CGPoint(x: f.minX + 5, y: f.minY + 2), to = CGPoint(x: f.maxX - 1, y: f.maxY - 2)
        v.mouseDown(at: from, clickCount: 1, modifiers: [])
        v.mouseDragged(to: CGPoint(x: f.midX, y: f.midY))
        v.mouseDragged(to: to)
        #expect(m.selectedKeyIDs(.opacity).count == 2)
        v.mouseUp(at: to)
        #expect(v.graph(.opacity).marqueeRect == nil && v.lanes.marquee == nil)
    }

    // MARK: Value mode (SpeedGraphRow's KeyframeGraphView per component)

    @Test func valueModeDrawsTheValueGraphAndItsMenuSwitchesBack() throws {
        let (v, f) = try view()
        let m = v.model
        m.setGraphMode(.value, for: .opacity)
        var c = Canvas(width: 900, height: 1200, atlas: nil, scale: 1)
        v.draw(&c)
        let g = try #require(v.valueGraphs(.opacity).first?.1)
        #expect(g.size.width == f.width && g.track.keys.count == 2)
        var shown: [SQMenuItem] = []
        v.onMenu = { items, _ in shown = items }
        v.mouseDown(at: CGPoint(x: f.midX, y: f.midY), clickCount: 1, modifiers: .secondary)
        #expect(Array(shown.map(\.title).prefix(2)) == ["Speed", "Value"])
        shown.first { $0.title == "Speed" }?.action?()
        #expect(m.graphMode(for: .opacity) == .speed)
    }

    @Test func valueModeKeyDragIsOneEdit() throws {
        let (v, f) = try view()
        let m = v.model
        m.setGraphMode(.value, for: .opacity)
        var c = Canvas(width: 900, height: 1200, atlas: nil, scale: 1)
        v.draw(&c)
        let g = try #require(v.valueGraphs(.opacity).first?.1)
        let key = g.geometry.keyPoint(track: g.track, index: 1)
        var edits = 0
        let pass = m.onEdit
        m.onEdit = { cl, n, k in edits += 1; pass?(cl, n, k) }
        let start = CGPoint(x: f.minX + key.x, y: f.minY + key.y)
        let before = m.graphTrack(.opacity, component: .all).keys[1].value
        v.mouseDown(at: start, clickCount: 1, modifiers: [])
        v.mouseDragged(to: CGPoint(x: start.x, y: start.y + 10))
        v.mouseDragged(to: CGPoint(x: start.x, y: start.y + 20))
        v.mouseUp(at: CGPoint(x: start.x, y: start.y + 20))
        #expect(edits == 1)
        #expect(m.graphTrack(.opacity, component: .all).keys[1].value < before)
    }
}
