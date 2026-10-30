import AppKit
import Testing
@testable import SQUIKit

/// Board "Other dialogs": `fld` + `unit` -- the unit sits to the right of the capsule, outside it. Gaps are measured between the
/// field's outline and the unit's own frame (the label draws from its left edge, no cell padding).
@MainActor @Suite struct DialogUnitLayoutTests {
    private func host(_ rows: [NSView]) -> (NSView, SQDialogForm) {
        let form = SQDialogForm(rows: rows)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 200))
        v.addSubview(form)
        form.leadingAnchor.constraint(equalTo: v.leadingAnchor).isActive = true
        form.topAnchor.constraint(equalTo: v.topAnchor).isActive = true
        form.widthAnchor.constraint(equalToConstant: 440).isActive = true
        v.layoutSubtreeIfNeeded()
        return (v, form)
    }

    private func frame(of view: NSView, in root: NSView) -> NSRect { root.convert(view.bounds, from: view) }

    @Test func unitSitsOutsideTheCapsuleAtTheControlGap() {
        let f = SQDialog.makeNumberField(value: 0.05, range: 0...60, step: 0.05, decimals: 2, unit: "s", width: nil)
        let (root, _) = host([SQDialog.formRow("Min. Duration", f)])
        let unit = root.allSubviews.compactMap { $0 as? SQUnitLabel }.first
        #expect(unit?.text == "s")
        let ff = frame(of: f, in: root), uf = unit.map { frame(of: $0, in: root) } ?? .zero
        #expect(abs((uf.minX - ff.maxX) - SQDialogMetrics.controlGap) < 0.5)
        #expect(f.displayText == "0.05")                 // the capsule holds the bare number
        #expect(abs(ff.width - SQDialogMetrics.unitFieldWidth) < 0.5)
    }

    @Test func rowsWithAndWithoutUnitsShareTheFieldEdge() {
        let a = SQDialog.makeNumberField(range: 0...60, unit: "frames", width: nil)
        let b = SQDialog.makeNumberField(range: 0...60, width: nil)
        let c = SQDialog.makeNumberField(range: 0...60, unit: "ms", width: 72)
        let (root, _) = host([SQDialog.formRow("Gap", a), SQDialog.formRow("Count", [b, NSView()]), SQDialog.formRow("Hold", c)])
        let xs = [a, b, c].map { frame(of: $0, in: root).minX }
        #expect(xs.allSatisfy { abs($0 - xs[0]) < 0.5 })
    }

    @Test func sliderUnitSitsOutsideAndKeepsOneFieldEdge() {
        let ms = NumericSlider(value: 10, range: 0...100, unit: "ms")
        let db = NumericSlider(value: 10, range: 0...100, unit: "dB")
        let none = NumericSlider(value: 10, range: 0...100)
        let (root, _) = host([SQDialog.formRow("A", ms), SQDialog.formRow("B", db), SQDialog.formRow("C", none)])
        #expect(ms.unitOutside && db.unitOutside && none.unitOutside)
        let gap = frame(of: ms.unitLabel, in: root).minX - frame(of: ms.field, in: root).maxX
        #expect(abs(gap - SQDialogMetrics.controlGap) < 0.5)
        let edges = [ms, db, none].map { frame(of: $0.field, in: root).maxX }
        #expect(edges.allSatisfy { abs($0 - edges[0]) < 0.5 })
        #expect(ms.field.displayText == "10")
    }
}

private extension NSView {
    var allSubviews: [NSView] { subviews + subviews.flatMap(\.allSubviews) }
}
