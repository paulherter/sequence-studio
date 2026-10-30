import AppKit
import SQCore
import SQUIKit

/// Review step of Remove Silences: one checkbox row per proposed cut (all on), "Remove Checked" cuts the checked
/// ones and drops the others in one undo step, "Reject All" drops every proposal, Cancel leaves the markers as they are.
@MainActor
public enum ProposedCutsReviewDialog {
    public enum Result: Equatable, Sendable {
        /// Cut these proposals, reject the rest.
        case accept(Set<Marker.ID>)
        case rejectAll
    }

    public static let listHeight: CGFloat = Theme.Row.list * 9

    /// "0:12.4   1.4 s": start in minutes:seconds and the length of the pause.
    public static func rowTitle(_ cut: Timeline.ProposedCut) -> String {
        func sec(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
        let start = max(sec(cut.range.start), 0)
        let m = Int(start) / 60
        let s = start - Double(m * 60)
        if cut.kind == .scene { return String(format: "%d:%04.1f   scene change", m, s) }
        return String(format: "%d:%04.1f   %.1f s", m, s, sec(cut.range.duration))
    }

    public static func summary(count: Int, checked: Int, removed: Time) -> String {
        guard count > 0 else { return "No proposed cuts." }
        let sec = Double(removed.value) / Double(removed.timescale)
        return "\(checked) of \(count) checked, \(String(format: "%.1f", sec)) s will be removed."
    }

    public static func present(on window: NSWindow, cuts: [Timeline.ProposedCut], completion: @escaping @MainActor (Result?) -> Void) {
        let alert = SQDialog()
        alert.messageText = "Review Silences"
        alert.informativeText = "Uncheck the pauses you want to keep. Checked ones are cut and the gaps closed."
        alert.width = SQModal.Size.s.width
        let ui = ReviewController(cuts: cuts)
        alert.accessoryView = ui.view
        alert.addButton("Remove Checked")
        alert.addButton("Cancel", role: .cancel)
        alert.addButton("Reject All", leading: true)
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                switch response {
                case .first: completion(.accept(ui.checkedIDs))
                case .third: completion(.rejectAll)
                default: completion(nil)
                }
                withExtendedLifetime(ui) {}
            }
        }
    }

    /// The accessory view and its state (a test renders and drives it).
    @MainActor
    public final class ReviewController: NSObject {
        public let cuts: [Timeline.ProposedCut]
        public let view: NSView
        let boxes: [SQCheckbox]
        private let summaryLabel = SQDialog.caption("")

        public init(cuts: [Timeline.ProposedCut]) {
            self.cuts = cuts
            boxes = cuts.map { c in
                let b = SQCheckbox(title: ProposedCutsReviewDialog.rowTitle(c), target: nil, action: nil)
                b.state = .on
                return b
            }
            let width = SQModal.Size.s.width - 2 * SQDialogMetrics.sidePad
            let doc = ReviewFlippedView()
            for (i, b) in boxes.enumerated() {
                b.frame = NSRect(x: 8, y: CGFloat(i) * Theme.Row.list, width: width - 16, height: Theme.Row.list)
                doc.addSubview(b)
            }
            doc.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(cuts.count) * Theme.Row.list)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: ProposedCutsReviewDialog.listHeight))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.documentView = doc
            let well = NSView(frame: scroll.frame)
            well.wantsLayer = true
            well.layer?.backgroundColor = Theme.Colors.field.cgColor
            well.layer?.cornerRadius = Theme.Radius.well
            well.layer?.masksToBounds = true
            scroll.autoresizingMask = [.width, .height]
            well.addSubview(scroll)
            summaryLabel.font = Theme.Typography.bodyStrong
            summaryLabel.textColor = Theme.Colors.label
            view = SQDialogForm(rows: [SQDialog.pad(well, SQDialogMetrics.insets(0, 0), height: ProposedCutsReviewDialog.listHeight),
                                       SQDialog.pad(summaryLabel, SQDialogMetrics.insets(0, 0))])
            super.init()
            for b in boxes { b.target = self; b.action = #selector(changed) }
            refresh()
        }

        @objc private func changed() { refresh() }

        public var checkedIDs: Set<Marker.ID> {
            Set(zip(cuts, boxes).filter { $0.1.state == .on }.map { $0.0.id })
        }

        func refresh() {
            let on = zip(cuts, boxes).filter { $0.1.state == .on }.map(\.0)
            summaryLabel.stringValue = ProposedCutsReviewDialog.summary(
                count: cuts.count, checked: on.count, removed: on.reduce(Time.zero) { $0 + $1.range.duration })
        }

        /// Row titles and summary line (tests).
        var labels: [String] { boxes.map(\.title) + [summaryLabel.stringValue] }
    }
}

private final class ReviewFlippedView: NSView {
    override var isFlipped: Bool { true }
}
