import AppKit
import Testing
import SQCore
import SQUIKit
@testable import SQEditorUI
@testable import SQInspectorUI

/// Measures the one inspector grid in the Graphics panel with a text layer selected: header height, separators between
/// sections, the value column and the control column's right edge.
@MainActor @Suite struct InspectorGridMeasureTests {
    private func makePanel(width: CGFloat = 360) -> (GraphicsPanelView, GraphicsEditor) {
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                          tracks: Timeline.defaultTracks(video: 2, audio: 1))
        let e = GraphicsEditor(session: EditorSession(project: Project(name: "P", timelines: [tl])))
        let v = GraphicsPanelView(editor: e)
        e.newGraphicsClip()
        e.addText()
        v.sync([.project, .selection])
        v.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
        v.layoutSubtreeIfNeeded()
        return (v, e)
    }

    private func visible<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        var out: [T] = []
        func walk(_ v: NSView) {
            if v.isHidden { return }
            if let t = v as? T { out.append(t) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }

    @Test func headersShareOneHeightAndSectionsTouch() {
        let (v, _) = makePanel()
        let sections = visible(v, InspectorSection.self)
        let headers = visible(v, InspectorSectionHeader.self)
        #expect(headers.count >= 5)
        let heights = Set(headers.map { v.convert($0.bounds, from: $0).height })
        #expect(heights == [ControlsGrid.headerHeight], "header heights \(heights)")
        // Sections that follow a sibling section start where it ends: no gap, so exactly one rule between two.
        for s in sections {
            guard let stack = s.superview as? NSStackView, let i = stack.arrangedSubviews.firstIndex(of: s), i > 0,
                  let prev = stack.arrangedSubviews[i - 1] as? InspectorSection, !prev.isHidden else { continue }
            let gap = min(abs(s.frame.minY - prev.frame.maxY), abs(prev.frame.minY - s.frame.maxY))    // flipped or not
            #expect(gap < 0.5, "gap before \(s.header.title): \(gap)")
            #expect(s.header.showsTopLine, "\(s.header.title) has its rule")
        }
    }

    @Test func valueColumnAndControlColumnEdges() {
        let (v, _) = makePanel()
        var firstXs = Set<CGFloat>()
        var maxRight: CGFloat = 0
        for r in visible(v, NSView.self) {
            guard let p = (r as? ControlsRowProbing)?.rowProbe, p.label != nil, let c = p.controls.first else { continue }
            firstXs.insert(c.minX)
            for c in p.controls { maxRight = max(maxRight, c.maxX) }
        }
        #expect(firstXs == [ControlsGrid.valueX], "value column x \(firstXs)")
        #expect(maxRight <= ControlsGrid.controlColumnMaxX + 0.5, "control column right edge \(maxRight)")
        // Wider panel: controls stay in the column.
        let (w, _) = makePanel(width: 520)
        var wide: CGFloat = 0
        for r in visible(w, NSView.self) {
            guard let p = (r as? ControlsRowProbing)?.rowProbe, p.label != nil else { continue }
            for c in p.controls { wide = max(wide, c.maxX) }
        }
        #expect(wide <= ControlsGrid.controlColumnMaxX + 0.5, "wide panel right edge \(wide)")
    }

    /// Letter spacing and line spacing sit side by side: the first number on the value column like every other row's
    /// first control, the second pair one grid gap after it.
    @Test func spacingPairIsAdjacentAndOnTheValueColumn() throws {
        let (v, _) = makePanel()
        let box = try #require(visible(v, IconScrubField.self).first)
        var rowView: NSView? = box
        while let r = rowView, !(r is ControlsRowProbing) { rowView = r.superview }
        let probe = try #require((rowView as? ControlsRowProbing)?.rowProbe)
        #expect(probe.label != nil, "the letter spacing icon is the row's label")
        #expect(probe.controls.count == 2, "controls \(probe.controls)")
        let number = probe.controls[0], pair = probe.controls[1]
        #expect(abs(number.minX - ControlsGrid.valueX) < 0.5, "number x \(number.minX)")
        #expect(abs(number.width - ControlsGrid.valueWidth) < 0.5)
        #expect(abs(pair.minX - number.maxX - ControlsGrid.gap) < 0.5, "gap \(pair.minX - number.maxX)")
        #expect(abs(pair.width - IconScrubField.iconWidth - ControlsGrid.valueWidth) < 0.5, "pair width \(pair.width)")
        // Every labeled row of the panel starts its first control on the same x (spacing, size, font axes).
        var xs = Set<CGFloat>()
        for r in visible(v, NSView.self) {
            guard let p = (r as? ControlsRowProbing)?.rowProbe, p.label != nil, let c = p.controls.first, !p.fullWidth else { continue }
            xs.insert(c.minX)
        }
        #expect(xs == [ControlsGrid.valueX], "first control x \(xs)")
    }

    @Test func appearanceLivesInTheTextSection() {
        let (v, _) = makePanel()
        let titles = visible(v, InspectorSectionHeader.self).map(\.title)
        #expect(titles.contains("Text"))
        #expect(!titles.contains("Appearance"), "titles \(titles)")
    }

    @Test func controlsShowsTheTextBoxOfATextLayer() {
        let (_, e) = makePanel()
        let rows = GraphicItemRows()
        rows.editor = e
        rows.refresh()
        #expect(!rows.textBox.isHidden)
        #expect(!rows.isHidden)
        #expect(rows.textBox.string == e.textTemplate?.text)
    }
}
