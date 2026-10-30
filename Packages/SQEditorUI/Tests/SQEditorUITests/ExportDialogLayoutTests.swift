import AppKit
import Foundation
import Testing
import SQCore
import SQExport
import SQUIKit
@testable import SQEditorUI

/// The export form fits the L modal (860 x 640) and keeps every option of the 880 x 680 form.
@MainActor @Suite struct ExportDialogLayoutTests {
    /// The options of the 880 x 680 form (listed before the rework): header, the settings column, the footer.
    private static let optionsBefore: [String] = [
        "Preset", "Add another output",
        "Codec", "Profile", "Size", "Frame Rate", "Rate Control", "Quality", "Bitrate", "Max Bitrate", "", "Encoder Speed", "Color Space", "Include Audio",
        "Codec", "Sample Rate", "Bitrate", "Normalize", "Audio Check", "Captions", "Range", "Duration", "Cover", "Keyframe Every", "B-Frames",
        "Alpha", "Bit Depth", "Channels", "Damaged Frames", "HDR to SDR",
        "Change…", "Cancel", "Export",
    ]
    /// File Name and Folder moved into the settings column's Output section (board), in front of Advanced.
    private static var optionsNow: [String] {
        var o = optionsBefore
        o.insert(contentsOf: ["File Name", "Folder"], at: o.firstIndex(of: "Keyframe Every")!)
        // A 10 s sequence is under 60 s: the greyed Loudness Range row follows Normalize.
        o.insert("Loudness Range", at: o.firstIndex(of: "Normalize")! + 1)
        return o
    }

    private func makeView() -> ExportDialogView {
        let items = [ExportDialogModel.SequenceItem(name: "Seq 1", duration: Time(seconds: 10))]
        let m = ExportDialogModel(sequences: items) { _, _ in throw CancellationError() }
        return ExportDialogView(model: m, onExport: {}, onCancel: {})
    }

    @Test func sizeIsTheLModal() {
        #expect(ExportDialogView.size == NSSize(width: 860, height: 640))
    }

    @Test func noOptionDropped() {
        let titles = makeView().optionTitles
        #expect(titles == Self.optionsNow, "\(titles)")
    }

    private func all(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap { all($0) } }

    /// The footer is the shared dialog footer row: 68 high band, 20 side inset, Cancel then Export, 8 apart, 26 high buttons.
    @Test func footerIsTheSharedDialogFooter() {
        let v = makeView()
        v.layoutSubtreeIfNeeded()
        let band = all(v).first { String(describing: type(of: $0)) == "SQDialogFooterBand" }
        #expect(band != nil)
        guard let band else { return }
        let bf = v.convert(band.bounds, from: band)
        #expect(abs(bf.height - Theme.Modal.footerHeight) < 0.5)
        #expect(abs(bf.width - Theme.Modal.widthL) < 0.5)
        #expect(abs(bf.maxY - Theme.Modal.heightL) < 0.5)
        let buttons = all(band).compactMap { $0 as? SQButton }.filter { !$0.isHidden }   // "Other Formats…" shows only when formats are given
        #expect(buttons.map(\.title) == ["Cancel", "Export"])
        guard buttons.count == 2 else { return }
        let c = v.convert(buttons[0].bounds, from: buttons[0]), e = v.convert(buttons[1].bounds, from: buttons[1])
        #expect(abs((Theme.Modal.widthL - e.maxX) - SQDialogMetrics.sidePad) < 0.5)
        #expect(abs((e.minX - c.maxX) - SQDialogMetrics.buttonGap) < 0.5)
        for f in [c, e] {
            #expect(abs(f.height - SQDialogMetrics.buttonHeight) < 0.5)
            #expect(abs(f.midY - bf.midY) < 0.5)
        }
    }

    /// Board `NUM` + `HN`: the unit sits after the capsule (84 wide), one row gap behind its outline; the capsule holds the bare number.
    @Test func numberFieldsKeepTheirUnitOutsideTheCapsule() {
        let v = makeView()
        v.layoutSubtreeIfNeeded()
        let rows = all(v).compactMap { $0 as? ExportSettingRow }
        let bitrate = rows.first { $0.title == "Bitrate" }
        let field = bitrate.flatMap { all($0).compactMap { $0 as? ScrubField }.first }
        let unit = bitrate.flatMap { all($0).compactMap { $0 as? SQUnitLabel }.first }
        #expect(field != nil && unit != nil)
        guard let field, let unit, let bitrate else { return }
        #expect(unit.text == "Mbit/s")
        #expect(field.displayText == ScrubMath.format(field.value, decimals: 1, unit: ""))
        let ff = bitrate.convert(field.bounds, from: field), uf = bitrate.convert(unit.bounds, from: unit)
        #expect(abs(ff.width - ExportDialogView.numberFieldWidth) < 0.5)
        #expect(abs((uf.minX - ff.maxX) - Theme.Spacing.sm) < 0.5)
    }

    /// A button that was never laid out has frame width 0: the row item takes its intrinsic width, so the button never
    /// shrinks under the hint beside it (the "Audio Check Check Audio" overlap) and "Loudness Range" fits its label column.
    @Test func fixedItemOfAnUnlaidButtonUsesItsIntrinsicWidth() {
        let b = SQButton(title: "Check Audio", target: nil, action: nil, style: .standard)
        #expect(b.frame.width == 0)
        let item = ExportSettingRow.Item.fixed(b)
        #expect(item.width == b.intrinsicContentSize.width && (item.width ?? 0) > 60)
        let label = NSTextField(labelWithString: "Loudness Range")
        label.font = Theme.Typography.body
        #expect(label.intrinsicContentSize.width <= ExportSettingRow.controlX - ExportSettingRow.labelX - Theme.Spacing.xs)
    }
}
