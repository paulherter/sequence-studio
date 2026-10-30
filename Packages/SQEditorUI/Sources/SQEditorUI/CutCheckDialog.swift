import AppKit
import SQCore
import SQEditorSession
import SQUIKit

/// Bar chart of the shot-length buckets (AppKit drawing). Board: 110 high, columns 8 apart, count (10 pt, label 2) above a
/// bar with 3 pt top corners in the accent fill, bucket label (10 pt, label 3) below, 3 pt between the three.
public final class ShotHistogramView: NSView {
    public var buckets: [ShotBucket] = [] { didSet { needsDisplay = true } }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        let font = Theme.Typography.caption
        let countAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.Colors.label2]
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.Colors.label3]
        guard !buckets.isEmpty else { return }
        let top = max(buckets.map(\.count).max() ?? 1, 1)
        let line: CGFloat = 12, gap: CGFloat = 3, gutter: CGFloat = 8
        let maxBar: CGFloat = 64
        let colW = (bounds.width - gutter * CGFloat(buckets.count - 1)) / CGFloat(buckets.count)
        let baseline = bounds.height - line - gap          // bottom of the bars
        for (i, b) in buckets.enumerated() {
            let x = CGFloat(i) * (colW + gutter)
            let h = b.count == 0 ? 0 : max(3, (maxBar * CGFloat(b.count) / CGFloat(top)).rounded())
            let bar = NSRect(x: x, y: baseline - h, width: colW, height: h)
            if h > 0 {
                let r: CGFloat = 3
                let p = NSBezierPath()
                p.move(to: NSPoint(x: bar.minX, y: bar.maxY))
                p.line(to: NSPoint(x: bar.minX, y: bar.minY + r))
                p.curve(to: NSPoint(x: bar.minX + r, y: bar.minY), controlPoint1: NSPoint(x: bar.minX, y: bar.minY + r * 0.45), controlPoint2: NSPoint(x: bar.minX + r * 0.45, y: bar.minY))
                p.line(to: NSPoint(x: bar.maxX - r, y: bar.minY))
                p.curve(to: NSPoint(x: bar.maxX, y: bar.minY + r), controlPoint1: NSPoint(x: bar.maxX - r * 0.45, y: bar.minY), controlPoint2: NSPoint(x: bar.maxX, y: bar.minY + r * 0.45))
                p.line(to: NSPoint(x: bar.maxX, y: bar.maxY))
                p.close()
                Theme.Colors.accentFill.setFill()
                p.fill()
            }
            let c = NSAttributedString(string: "\(b.count)", attributes: countAttrs)
            c.draw(at: NSPoint(x: x + (colW - c.size().width) / 2, y: bar.minY - gap - line + (line - c.size().height) / 2))
            let l = NSAttributedString(string: b.label, attributes: labelAttrs)
            l.draw(at: NSPoint(x: x + (colW - l.size().width) / 2, y: baseline + gap + (line - l.size().height) / 2))
        }
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .image }
    public override func accessibilityLabel() -> String? {
        "Shot lengths: " + buckets.map { "\($0.label) \($0.count)" }.joined(separator: ", ")
    }
}

/// Content of the Check Cuts sheet: platform picker, finding counts, stats, histogram.
@MainActor
public final class CutCheckSheetView: NSView {
    public static let platformKey = "sq.cutCheck.platform"
    public private(set) var form: SQDialogForm!
    private let picker = SQSegmented(labels: CutCheckPlatform.allCases.map(\.title), segmentWidth: 0)
    private let text = NSTextField(wrappingLabelWithString: "")
    private let histogram = ShotHistogramView()
    private let rerun: (CutCheckPlatform) -> CutCheckReport?
    public var onChange: ((CutCheckReport) -> Void)?

    public init(report: CutCheckReport, rerun: @escaping (CutCheckPlatform) -> CutCheckReport?) {
        self.rerun = rerun
        super.init(frame: NSRect(x: 0, y: 0, width: 432, height: 300))
        picker.target = self; picker.action = #selector(platformChanged)
        picker.selectedSegment = CutCheckPlatform.allCases.firstIndex(of: report.platform) ?? 0
        picker.setAccessibilityLabel("Safe zone platform")
        picker.setContentHuggingPriority(.required, for: .horizontal)
        text.font = Theme.Typography.body
        text.textColor = Theme.Colors.label2
        text.preferredMaxLayoutWidth = SQModal.Size.s.width - SQDialogMetrics.sidePad * 2 - SQDialogMetrics.labelWidth - SQDialogMetrics.labelGap
        let chartTitle = NSTextField(labelWithString: "Shot length")
        chartTitle.font = Theme.Typography.bodyStrong; chartTitle.textColor = Theme.Colors.label2
        // Board: one block (padding 8 / 16 / 0), 8 between note, chart title and the 110 high chart.
        let block = NSStackView(views: [text, chartTitle, histogram])
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 8
        histogram.heightAnchor.constraint(equalToConstant: 110).isActive = true
        histogram.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
        // Board: the block sits in the control column, under the picker (same left edge as the controls above it).
        var indent = SQDialogMetrics.insets(0, 0)
        indent.left += SQDialogMetrics.labelWidth + SQDialogMetrics.labelGap
        let blockRow = SQDialog.pad(block, indent)
        form = SQDialogForm(rows: [SQDialog.formRow("Safe Zone", picker), blockRow])
        histogram.translatesAutoresizingMaskIntoConstraints = false
        show(report)
    }
    public required init?(coder: NSCoder) { fatalError() }

    public func show(_ r: CutCheckReport) {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = SQDialogMetrics.noteLine; p.maximumLineHeight = SQDialogMetrics.noteLine
        text.attributedStringValue = NSAttributedString(string: r.boardSummary, attributes: [
            .font: Theme.Typography.body, .foregroundColor: Theme.Colors.label2, .baselineOffset: 2, .paragraphStyle: p])
        histogram.buckets = r.stats.histogram
    }

    @objc private func platformChanged() {
        let p = CutCheckPlatform.allCases[max(picker.selectedSegment, 0)]
        UserDefaults.standard.set(p.rawValue, forKey: Self.platformKey)
        if let r = rerun(p) { show(r); onChange?(r) }
    }
}
