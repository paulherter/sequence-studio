import AppKit
import SQCore
import SQUIKit

/// Sheet content of Sequence > Punch In Cuts…: zoom levels, ease, pattern.
@MainActor
public final class PunchInCutsSheetView: NSView {
    private let boxes = PunchInCutsOptions.scaleChoices.map { v -> SQCheckbox in
        let b = SQCheckbox(title: v == 100 ? "100 % (no zoom)" : (v == v.rounded() ? "\(Int(v)) %" : String(format: "%.1f %%", v)), target: nil, action: nil)
        b.tag = Int(v * 10)
        return b
    }
    public private(set) var form: SQDialogForm!
    private let ease = SQPopup(frame: .zero, pullsDown: false)
    private let pattern = SQSegmented(labels: ["Alternate", "Cycle"], segmentWidth: 0)

    public init(_ initial: PunchInCutsOptions) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 190))
        for b in boxes { b.state = initial.scales.contains(Double(b.tag) / 10) ? .on : .off }
        ease.addItems(withTitles: PunchInCutsOptions.Ease.allCases.map(\.title))
        ease.selectItem(at: PunchInCutsOptions.Ease.allCases.firstIndex(of: initial.ease) ?? 0)
        pattern.selectedSegment = initial.pattern == .alternate ? 0 : 1
        var indent = SQDialogMetrics.insets(0, 0)
        indent.left += SQDialogMetrics.labelWidth + SQDialogMetrics.labelGap
        let levels = boxes.enumerated().map { i, b in
            i == 0 ? SQDialog.formRow("Zoom", b) : SQDialog.pad(b, indent, height: 24)
        }
        form = SQDialogForm(rows: [SQDialog.formRow("Pattern", pattern), SQDialog.formRow("Ease", ease)] + levels)
    }
    public required init?(coder: NSCoder) { fatalError() }

    public var options: PunchInCutsOptions {
        PunchInCutsOptions(scales: boxes.filter { $0.state == .on }.map { Double($0.tag) / 10 },
                           ease: PunchInCutsOptions.Ease.allCases[max(ease.indexOfSelectedItem, 0)],
                           pattern: pattern.selectedSegment == 0 ? .alternate : .cyclic)
    }
}
