import AppKit
import SQCore
import SQEditorSession
import SQUIKit
import Testing
@testable import SQEditorUI

/// Settings pages: every number row of a page shares one field edge and one unit edge (shared dialog rule: the unit sits after
/// the capsule, `controlGap` from its outline), at the narrowest and at a wide window.
@MainActor @Suite struct SettingsUnitLayoutTests {
    private static let widths: [CGFloat] = [560, 1200]

    private func host(_ rows: [NSView], width: CGFloat) -> NSView {
        let page = SQFormRow.page(rows)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        v.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: v.leadingAnchor), page.topAnchor.constraint(equalTo: v.topAnchor),
            page.widthAnchor.constraint(equalToConstant: width),
        ])
        v.layoutSubtreeIfNeeded()
        return v
    }

    private func frame(_ view: NSView, in root: NSView) -> NSRect { root.convert(view.bounds, from: view) }

    private func units(in root: NSView) -> [SQUnitLabel] { all(root).compactMap { $0 as? SQUnitLabel } }
    private func fields(in root: NSView) -> [ScrubField] { all(root).compactMap { $0 as? ScrubField } }
    private func all(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap { all($0) } }

    private func expectOneEdge(_ root: NSView, count: Int, width: CGFloat) {
        let fs = fields(in: root), us = units(in: root)
        #expect(fs.count == count)
        #expect(us.count == count)
        let fx = fs.map { frame($0, in: root).minX }, ux = us.map { frame($0, in: root).minX }
        #expect(fx.allSatisfy { abs($0 - fx[0]) < 0.5 }, "field edges \(fx) at \(width)")
        #expect(ux.allSatisfy { abs($0 - ux[0]) < 0.5 }, "unit edges \(ux) at \(width)")
        for (f, u) in zip(fs, us) {
            #expect(abs(frame(f, in: root).width - SQFormRow.numberWidth) < 0.5)
            #expect(abs((frame(u, in: root).minX - frame(f, in: root).maxX) - SQDialogMetrics.controlGap) < 0.5)
            #expect(f.displayText == ScrubMath.format(f.value, decimals: f.decimals, unit: ""))   // the capsule holds the bare number
        }
    }

    @Test func editingPageTransitionRowsShareOneFieldAndUnitEdge() {
        for w in Self.widths {
            let video = SQDialog.makeNumberField(range: 0...10_000, defaultValue: 0, width: nil)
            let audio = SQDialog.makeNumberField(value: 1, range: 0.05...600, step: 0.05, decimals: 2, defaultValue: 1, width: nil)
            let rows = [SQFormRow.caption("Default transition length"),
                        SQFormRow.numberRow("Video Transition", field: video, unit: "frames", note: "· 0 means 1 second", help: "Help"),
                        SQFormRow.numberRow("Audio Transition", field: audio, unit: "seconds")]
            expectOneEdge(host(rows, width: w), count: 2, width: w)
        }
    }

    @Test func audioPageDuckTimingGridSharesOneFieldAndUnitEdge() {
        for w in Self.widths {
            let timing = DuckTimingForm(timing: DuckTiming.classic)
            let grid = SQFormRow.unitGrid(timing.titledFields)
            let rows = [SQFormRow.row("Duck Timing", SQFormRow.width(timing.preset, 180), extra: [grid])]
            let root = host(rows, width: w)
            expectOneEdge(root, count: 5, width: w)
            #expect(units(in: root).allSatisfy { $0.text == "ms" })
        }
    }
}
