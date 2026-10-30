import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// The shared-toolkit Effect Controls (Windows): the Mac rows and actions through the draw-list panel.
@MainActor @Suite struct EffectControlsDrawPanelTests {
    private func panel() -> EffectControlsDrawPanel {
        let c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let m = EffectControlsModel()
        m.setClip(c)
        let p = EffectControlsDrawPanel(model: m)
        p.size = CGSize(width: 420, height: 2000)
        return p
    }

    private func center(_ p: EffectControlsDrawPanel, _ kind: EffectRow.Kind, x: CGFloat) -> CGPoint? {
        guard let r = p.rows.first(where: { $0.kind == kind }) else { return nil }
        return CGPoint(x: x, y: r.y + r.height / 2)
    }

    @Test func keyHueEyedropperSetsTheHueOnceAndAGraySpotOnlyWarns() throws {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let e = try #require(c.addEffect(kind: ClipEffect.ultraKeyKind).flatMap { id in c.effects.first { $0.id == id } })
        let m = EffectControlsModel()
        m.setClip(c)
        m.collapsedSections = []      // effect sections start collapsed
        let p = EffectControlsDrawPanel(model: m)
        p.size = CGSize(width: 420, height: 3000)
        let hue = EffectProperty.fx(e.id, kind: ClipEffect.ultraKeyKind, key: ClipEffect.keyHueKey)
        let at = try #require(center(p, .property(hue), x: ControlsGrid.valueColumn(1) + ControlsGrid.controlHeight / 2))
        #expect(p.target(at: at) != .keyPick(hue))           // no screen sampler: no eyedropper
        var sample = SQColorValue(r: 0.1, g: 0.2, b: 0.9)     // a blue screen
        var notices: [String] = [], edits = 0
        m.onNotice = { notices.append($0) }
        m.onEdit = { _, _, _ in edits += 1 }
        p.sampleScreenColor = { done in done(sample) }
        #expect(p.target(at: at) == .keyPick(hue))
        #expect(p.help(at: at) == "Pick Key Color from Monitor")
        p.mouseDown(at: at, clickCount: 1, modifiers: []); p.mouseUp(at: at)
        let want = try #require(KeyColorPick.hue(fromLinear: EffectControlsModel.linear(fromSRGB: 0.1, 0.2, 0.9)))
        #expect(abs(want - 238) <= 1)                       // linear light, like the Mac frame readback
        #expect(m.scalarValue(hue) == want)
        #expect(edits == 1 && notices.isEmpty)
        sample = SQColorValue(r: 0.5, g: 0.5, b: 0.5)
        p.mouseDown(at: at, clickCount: 1, modifiers: []); p.mouseUp(at: at)
        #expect(m.scalarValue(hue) == want)
        #expect(notices == [EffectControlsModel.keyPickGrayNotice])
    }

    @Test func emptyStateShowsOnlyWithoutAClip() {
        let p = panel()
        #expect(!p.showsEmptyState)
        p.model.setClip(nil)
        #expect(p.showsEmptyState)
        var canvas = Canvas(width: 420, height: 600, atlas: nil, scale: 1)
        p.draw(&canvas)
    }

    @Test func rowsAreTheMacLayout() {
        let p = panel(), m = p.model
        let mac = EffectControlsLayout.rows(sections: m.visibleSections, collapsed: m.collapsedSections, expanded: m.expanded,
                                            blendModeRow: true, groupHeaders: false, openColorGroups: m.openColorGroups,
                                            subjectMasks: m.subjectMaskIDs, pictureMasks: m.pictureMaskIDs,
                                            colorRangeMasks: m.colorRangeMaskIDs, gradeRanges: m.gradeRangeEffects,
                                            stabilizers: m.stabilizerMethods, transformCrop: m.transformCropProperties)
        #expect(p.rows == mac)
        #expect(p.rows.contains { $0.kind == .blendMode })
    }

    @Test func draggingTheOpacityFieldIsOneGestureOnTheModel() throws {
        let p = panel(), m = p.model
        var names: [String] = []
        m.onEdit = { _, n, _ in names.append(n) }
        let at = try #require(center(p, .property(.opacity), x: ControlsGrid.valueColumn(0) + 10))
        #expect(p.target(at: at) == .field(.init(ref: .property(.opacity), component: .all)))
        let before = m.scalarValue(.opacity)
        p.mouseDown(at: at, clickCount: 1, modifiers: [])
        p.mouseDragged(to: CGPoint(x: at.x - 30, y: at.y))
        p.mouseUp(at: CGPoint(x: at.x - 30, y: at.y))
        #expect(m.scalarValue(.opacity) < before)
        #expect(Set(names).count == 1)
    }

    @Test func clickTypesAValueAndEnterCommits() throws {
        let p = panel(), m = p.model
        let at = try #require(center(p, .property(.opacity), x: ControlsGrid.valueColumn(0) + 10))
        p.mouseDown(at: at, clickCount: 1, modifiers: [])
        p.mouseUp(at: at)
        let id = EffectControlsDrawPanel.FieldID(ref: .property(.opacity), component: .all)
        #expect(p.focusedField == id && p.fields[id]?.isEditing == true)
        for ch in "40" { p.key(.character(ch), modifiers: []) }
        p.key(.enter, modifiers: [])
        #expect(abs(m.scalarValue(.opacity) - EffectProperty.opacity.native(fromDisplay: 40)) < 1e-9)
        #expect(p.focusedField == nil)
    }

    @Test func commandZLeavesAnOpenFieldAndGoesOnToTheApp() throws {
        let p = panel()
        let at = try #require(center(p, .property(.opacity), x: ControlsGrid.valueColumn(0) + 10))
        p.mouseDown(at: at, clickCount: 1, modifiers: [])
        p.mouseUp(at: at)
        #expect(p.focusedField != nil)
        #expect(!p.key(.character("z"), modifiers: .command))
        #expect(p.focusedField == nil)
        #expect(!p.key(.character("z"), modifiers: [.command, .shift]))
    }

    @Test func doubleClickOnAFieldResetsTheRow() throws {
        let p = panel(), m = p.model
        _ = m.setValue(.opacity, to: 0.25)
        p.syncFields()
        let at = try #require(center(p, .property(.opacity), x: ControlsGrid.valueColumn(0) + 10))
        p.mouseDown(at: at, clickCount: 1, modifiers: []); p.mouseUp(at: at)
        p.mouseDown(at: at, clickCount: 2, modifiers: []); p.mouseUp(at: at)
        #expect(m.isDefault(.opacity))
    }

    @Test func ringStartsAnimationAndTheChevronCollapses() throws {
        let p = panel(), m = p.model
        let ringAt = try #require(center(p, .property(.opacity), x: ControlsGrid.toggleMidX))
        p.mouseDown(at: ringAt, clickCount: 1, modifiers: []); p.mouseUp(at: ringAt)
        #expect(m.keyframeControlState(.opacity).showsNavigation)
        let section = try #require(p.rows.first { if case .section = $0.kind { true } else { false } })
        guard case .section(let s) = section.kind else { return }
        let chevron = CGPoint(x: ControlsGrid.headerToggleMidX, y: section.y + section.height / 2)
        #expect(p.target(at: chevron) == .chevron(s))
        p.mouseDown(at: chevron, clickCount: 1, modifiers: []); p.mouseUp(at: chevron)
        #expect(m.collapsedSections.contains(s))
        #expect(p.rows.count < EffectControlsLayout.rows(sections: m.visibleSections, collapsed: [], expanded: [], blendModeRow: true,
                                                         groupHeaders: false, openColorGroups: m.openColorGroups,
                                                         subjectMasks: m.subjectMaskIDs, pictureMasks: m.pictureMaskIDs,
                                                         colorRangeMasks: m.colorRangeMaskIDs, gradeRanges: m.gradeRangeEffects,
                                                         stabilizers: m.stabilizerMethods,
                                                         transformCrop: m.transformCropProperties).count)
    }

    @Test func blendPopupOffersTheMacSectionsAndPicks() throws {
        let p = panel(), m = p.model
        var shown: [SQMenuItem] = []
        p.onMenu = { items, _ in shown = items }
        let grid = ControlsGrid(width: p.size.width)
        let at = try #require(center(p, .blendMode, x: ControlsGrid.valueX + 20))
        #expect(at.x < grid.valueMaxX)
        p.mouseDown(at: at, clickCount: 1, modifiers: []); p.mouseUp(at: at)
        let modes = shown.filter { $0.kind == .action }
        #expect(modes.count == BlendMode.menuSections.joined().count)
        #expect(shown.filter { $0.kind == .separator }.count == BlendMode.menuSections.count - 1)
        #expect(modes.first { $0.isChecked }?.title == BlendMode.normal.title)
        let multiply = try #require(modes.first { $0.title == BlendMode.multiply.title })
        multiply.action?()
        #expect(m.blendMode == .multiply)
    }

    @Test func sectionContextMenuIsTheMacOne() throws {
        let p = panel()
        var shown: [SQMenuItem] = []
        p.onMenu = { items, _ in shown = items }
        let at = try #require(center(p, .property(.opacity), x: ControlsGrid.labelX + 4))
        p.contextMenu(at: at)
        #expect(shown.map(\.title).contains("Reset"))
        let section = try #require(p.rows.first { if case .section = $0.kind { true } else { false } })
        p.contextMenu(at: CGPoint(x: 100, y: section.y + 4))
        #expect(shown.contains { $0.title.hasPrefix("Reset") })
    }

    @Test func drawsEveryRowIntoTheList() {
        let p = panel()
        var c = Canvas(width: 420, height: 2000, atlas: nil, scale: 1)
        p.draw(&c)
        let img = SoftwareRenderer.render(c.list, width: 420, height: 400, clear: .black, atlas: nil)
        // The panel fill covers the canvas (no black left at a row's empty middle).
        #expect(img.pixels[(5 * 420 + 200) * 4 + 3] == 255)
        #expect(img.pixels[(5 * 420 + 200) * 4] > 0)
    }

    @Test func middleCutKeepsBothEnds() {
        let s = EffectControlsDrawPanel.middleCut("Position Width", width: 8) { CGFloat($0.count) }
        #expect(s.count <= 8 && s.hasPrefix("P") && s.hasSuffix("h") && s.contains("…"))
        #expect(EffectControlsDrawPanel.middleCut("Scale", width: 20) { CGFloat($0.count) } == "Scale")
    }
}
