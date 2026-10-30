import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQInspectorUI

/// The translated Mac rows in the shared-toolkit Effect Controls: masks, color range, grade range, color groups, Tab, tooltips.
@MainActor @Suite struct EffectControlsDrawRowsTests {
    private func panel(_ kind: TrackKind = .video, _ edit: (inout Clip) -> Void = { _ in }) -> EffectControlsDrawPanel {
        var c = Clip(name: "v", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero,
                     mediaDuration: Time(100, 1))
        edit(&c)
        let m = EffectControlsModel()
        m.onGestureEnded = {}
        m.setClip(c)
        m.collapsedSections = []      // effect sections start collapsed
        let p = EffectControlsDrawPanel(model: m)
        p.size = CGSize(width: 420, height: 3000)
        return p
    }

    private func click(_ p: EffectControlsDrawPanel, _ key: String, count: Int = 1) throws {
        let f = try #require(p.widgetFrameInPanel(key))
        let at = CGPoint(x: f.midX, y: f.midY)
        p.mouseDown(at: at, clickCount: count, modifiers: [])
        p.mouseUp(at: at)
    }

    @Test func maskInvertTogglesAndModePopupPicks() throws {
        let mask = ClipMask.make(.ellipse, name: "Mask (1)")
        let p = panel { $0.masks = [mask] }, m = p.model
        let row = EffectControlsDrawPanel.rowKey(.maskControls(mask.id))
        try click(p, row + ".invert")
        #expect(m.clip?.mask(mask.id)?.inverted == true)
        var shown: [SQMenuItem] = []
        p.onMenu = { items, _ in shown = items }
        try click(p, row + ".mode")
        #expect(shown.map(\.title) == MaskMode.allCases.map(\.title))
        let pick = try #require(MaskMode.allCases.first { $0 != m.clip?.mask(mask.id)?.mode })
        shown.first { $0.title == pick.title }?.action?()
        #expect(m.clip?.mask(mask.id)?.mode == pick)
        let f = try #require(p.widgetFrameInPanel(row + ".mode"))
        #expect(p.help(at: CGPoint(x: f.midX, y: f.midY)) == "Mask Mode")
    }

    @Test func colorRangeToleranceFieldDragsAsOneGesture() throws {
        let p = panel(), m = p.model
        let id = try #require(m.addColorRangeMask(key: ColorRangeKey(red: 0, green: 1, blue: 0, tolerance: 0.4, softness: 0.2)))
        m.collapsedSections = []
        p.relayout()
        var names: [String] = []
        m.onEdit = { _, n, _ in names.append(n) }
        let f = try #require(p.widgetFrameInPanel(EffectControlsDrawPanel.rowKey(.colorRangeAmount(id, soft: false)) + ".field"))
        let at = CGPoint(x: f.minX + 10, y: f.midY)
        p.mouseDown(at: at, clickCount: 1, modifiers: [])
        p.mouseDragged(to: CGPoint(x: at.x + 20, y: at.y))
        p.mouseUp(at: CGPoint(x: at.x + 20, y: at.y))
        #expect((m.colorRange(of: id)?.tolerance ?? 0) > 0.4)
        #expect(Set(names).count == 1)
    }

    @Test func gradeRangeTimecodeCommitsOnEnterAndTabMovesOn() throws {
        var effect: ClipEffect.ID?
        let p = panel { c in
            _ = c.addEffect(kind: ClipEffect.colorKind)
            effect = c.addRangeGrade(TimeRange(start: Time(2, 1), end: Time(6, 1)))
        }
        let m = p.model, id = try #require(effect)
        let row = EffectControlsDrawPanel.rowKey(.gradeRange(id))
        try click(p, row + ".start")
        #expect(p.focusedText == row + ".start")
        let fd = m.frameDuration
        for ch in MarkersPanelModel.timecode(Time(1, 1), frameDuration: fd) { p.key(.character(ch), modifiers: []) }
        p.key(.enter, modifiers: [])
        #expect(m.gradeRange(id)?.start == Time(1, 1))
        #expect(p.focusedText == nil)
        try click(p, row + ".start")
        p.key(.tab, modifiers: [])
        #expect(p.focusedText == row + ".end")
        p.key(.tab, modifiers: [.shift])
        #expect(p.focusedText == row + ".start")
    }

    @Test func colorGroupDisclosureOpensAndItsBoxEnables() throws {
        let p = panel { _ = $0.addEffect(kind: ClipEffect.colorKind) }, m = p.model
        let row = try #require(p.rows.first { if case .colorGroup = $0.kind { true } else { false } })
        guard case .colorGroup(let effect, let group) = row.kind else { return }
        let key = EffectControlsDrawPanel.rowKey(row.kind) + ".disclosure"
        let wasOpen = m.openColorGroups.contains(EffectControlsModel.colorGroupID(effect, group))
        let count = p.rows.count
        try click(p, key)
        #expect(m.openColorGroups.contains(EffectControlsModel.colorGroupID(effect, group)) != wasOpen)
        #expect(p.rows.count != count)
        let (r, w) = try #require(p.widget(key))
        let box = try #require(w.toggleFrame).offsetBy(dx: 0, dy: p.rowTopInPanel(r))
        let at = CGPoint(x: box.midX, y: box.midY)
        #expect(p.target(at: at) == .widgetToggle(key))
        let prop = EffectProperty.fx(effect, kind: ClipEffect.colorKind, key: group)
        let before = m.scalarValue(prop) >= 0.5
        p.mouseDown(at: at, clickCount: 1, modifiers: []); p.mouseUp(at: at)
        #expect((m.scalarValue(prop) >= 0.5) != before)
    }

    @Test func curvesPickAChannelAndAddAPointAsOneGesture() throws {
        let p = panel { _ = $0.addEffect(kind: ClipEffect.colorKind) }, m = p.model
        guard let row = p.rows.first(where: { if case .curves = $0.kind { true } else { false } }) else {
            // The Curves group starts closed: open it like a click on its disclosure.
            let header = try #require(p.rows.first { if case .colorGroup(_, let k) = $0.kind { k.lowercased().contains("curve") } else { false } })
            guard case .colorGroup(let e, let k) = header.kind else { return }
            m.toggleColorGroup(e, k); p.relayout()
            return try curvesPickAChannelAndAddAPointAsOneGestureOpen(p)
        }
        _ = row
        try curvesPickAChannelAndAddAPointAsOneGestureOpen(p)
    }

    private func curvesPickAChannelAndAddAPointAsOneGestureOpen(_ p: EffectControlsDrawPanel) throws {
        let m = p.model
        let row = try #require(p.rows.first { if case .curves = $0.kind { true } else { false } })
        guard case .curves(let effect) = row.kind else { return }
        let key = EffectControlsDrawPanel.rowKey(row.kind) + ".curves"
        let (r, w) = try #require(p.widget(key))
        guard case .surface(let make) = w.kind, let s = p.surface(key, make) as? ColorCurvesSurface else { Issue.record("no surface"); return }
        let top = p.rowTopInPanel(r)
        let red = s.dotRect(1, w.frame)
        p.mouseDown(at: CGPoint(x: red.midX, y: red.midY + top), clickCount: 1, modifiers: []); p.mouseUp(at: CGPoint(x: red.midX, y: red.midY + top))
        #expect(s.channel == 1)
        var names: [String] = []
        m.onEdit = { _, n, _ in names.append(n) }
        let plot = s.plot(w.frame)
        let at = CGPoint(x: plot.minX + plot.width * 0.5, y: plot.minY + plot.height * 0.3 + top)
        p.mouseDown(at: at, clickCount: 1, modifiers: [])
        p.mouseDragged(to: CGPoint(x: at.x, y: at.y - 10))
        p.mouseUp(at: CGPoint(x: at.x, y: at.y - 10))
        let c = m.colorCurves(effect)
        #expect(c.red.count == 3 && c.master == RGBCurves.diagonal)
        #expect(c.red[1].y > 0.7)
        #expect(Set(names).count == 1)
        let rp = CGPoint(x: plot.minX + CGFloat(c.red[1].x) * plot.width, y: plot.minY + (1 - CGFloat(c.red[1].y)) * plot.height + top)
        p.mouseDown(at: rp, clickCount: 2, modifiers: []); p.mouseUp(at: rp)
        #expect(m.colorCurves(effect).red.count == 2)
    }

    @Test func eqCurveDragsABandAndScrollSetsQ() throws {
        let p = panel(.audio) { _ = $0.addEffect(kind: ClipEffect.audioParametricEQKind) }, m = p.model
        var row = p.rows.first { if case .eqCurve = $0.kind { true } else { false } }
        if row == nil, let h = p.rows.first(where: { if case .eqCurveHeader = $0.kind { true } else { false } }), case .eqCurveHeader(let e) = h.kind {
            m.toggleEQCurve(e); p.relayout()
            row = p.rows.first { if case .eqCurve = $0.kind { true } else { false } }
        }
        let r = try #require(row)
        guard case .eqCurve(let effect) = r.kind else { return }
        let key = EffectControlsDrawPanel.rowKey(r.kind) + ".curve"
        let (_, w) = try #require(p.widget(key))
        guard case .surface(let make) = w.kind, let s = p.surface(key, make) as? EQCurveSurface else { Issue.record("no surface"); return }
        let v = try #require(m.eqValues(effect))
        let band = try #require((1...7).first { v[$0].on })
        let top = p.rowTopInPanel(r)
        let at0 = s.pointPosition(band, v, s.geometry(w.frame))
        let at = CGPoint(x: at0.x, y: at0.y + top)
        p.mouseDown(at: at, clickCount: 1, modifiers: [])
        p.mouseDragged(to: CGPoint(x: at.x + 30, y: at.y - 20))
        p.mouseUp(at: CGPoint(x: at.x + 30, y: at.y - 20))
        let after = try #require(m.eqValues(effect))
        #expect(after[band].hz > v[band].hz && after[band].gainDB > v[band].gainDB)
        let moved = s.pointPosition(band, after, s.geometry(w.frame))
        #expect(p.scroll(at: CGPoint(x: moved.x, y: moved.y + top), dy: 40, precise: true, modifiers: []))
        #expect(abs((m.eqValues(effect)?[band].q ?? 0) - after[band].q * 2) < 1e-6 || m.eqValues(effect)?[band].q == 10)
        #expect(p.help(at: CGPoint(x: moved.x, y: moved.y + top))?.hasPrefix("Drag a point") == true)
    }

    @Test func translatedRowsDraw() throws {
        let mask = ClipMask.make(.ellipse, name: "Mask (1)")
        let p = panel { c in c.masks = [mask]; _ = c.addEffect(kind: ClipEffect.colorKind) }
        var c = Canvas(width: 420, height: 3000, atlas: nil, scale: 1)
        p.draw(&c)
        #expect(!c.list.quads.isEmpty)
    }
}
