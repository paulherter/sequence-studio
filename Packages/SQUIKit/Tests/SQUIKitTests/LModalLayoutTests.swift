import AppKit
import Testing
@testable import SQUIKit

/// The L modals (Card Import, Keyboard Shortcuts) are built with `SQDialog.cardContent` + `footerRow` and a body of
/// `SQDialogMetrics.lBodyHeight`. Measured offscreen: card size, footer height, paddings and button gaps.
@MainActor @Suite struct LModalLayoutTests {
    private func button(_ title: String, accent: Bool = false) -> SQButton {
        let b = SQButton(title: title, target: nil, action: nil, style: accent ? .accent : .standard)
        b.horizontalPadding = SQDialogMetrics.buttonPadding
        b.boxHeight = SQDialogMetrics.buttonHeight
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private struct Built { let card: NSView; let band: NSView; let left: [NSView]; let right: [NSView] }

    private func card(title: String, left: [NSView], right: [NSView]) -> Built {
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.heightAnchor.constraint(equalToConstant: SQDialogMetrics.lBodyHeight).isActive = true
        let footer = SQDialog.footerRow(left: left, right: right)
        let t = SQDialogText(.title, title, width: Theme.Modal.widthL - SQDialogMetrics.sidePad * 2)
        let card = SQDialog.cardContent(title: t, note: nil, body: body, footer: footer, width: Theme.Modal.widthL)
        card.frame = NSRect(origin: .zero, size: NSSize(width: Theme.Modal.widthL, height: Theme.Modal.heightL))
        card.layoutSubtreeIfNeeded()
        return Built(card: card, band: footer, left: left, right: right)
    }

    /// Card Import's footer: Select All on the left; status text, Import without Copying, Copy & Import on the right.
    private func cardImportLike() -> Built {
        let status = SQDialog.caption("3 selected")
        status.setContentHuggingPriority(.required, for: .horizontal)
        return card(title: "Import from SONY A7", left: [button("Select All")],
                    right: [status, button("Import without Copying"), button("Copy & Import", accent: true)])
    }

    /// Keyboard Shortcuts' footer: three small buttons left, Done right.
    private func shortcutsLike() -> Built {
        card(title: "Keyboard Shortcuts", left: [button("Set Shortcut…"), button("Assign to K"), button("Remove")],
             right: [button("Done", accent: true)])
    }

    private func frame(_ v: NSView, in root: NSView) -> NSRect { root.convert(v.bounds, from: v) }

    @Test func cardIsTheLModal() {
        for b in [cardImportLike(), shortcutsLike()] {
            #expect(abs(b.card.fittingSize.width - Theme.Modal.widthL) < 0.5)
            #expect(abs(b.card.fittingSize.height - Theme.Modal.heightL) < 0.5, "\(b.card.fittingSize)")
        }
    }

    @Test func footerBandAndPaddingsFollowTheModalTokens() {
        for b in [cardImportLike(), shortcutsLike()] {
            let band = frame(b.band, in: b.card)
            #expect(abs(band.height - Theme.Modal.footerHeight) < 0.5)
            #expect(abs(band.width - Theme.Modal.widthL) < 0.5)
            let first = frame(b.left[0], in: b.card), last = frame(b.right.last!, in: b.card)
            #expect(abs(first.minX - SQDialogMetrics.sidePad) < 0.5)
            #expect(abs((Theme.Modal.widthL - last.maxX) - SQDialogMetrics.sidePad) < 0.5)
            for v in b.left + b.right {
                let f = frame(v, in: b.card)
                #expect(abs(f.midY - band.midY) < 0.5)
                if v is SQButton { #expect(abs(f.height - SQDialogMetrics.buttonHeight) < 0.5) }
            }
        }
    }

    @Test func buttonOrderAndGapsMatchTheOtherLDialogs() {
        for b in [cardImportLike(), shortcutsLike()] {
            let xs = (b.left + b.right).map { frame($0, in: b.card).minX }
            #expect(xs == xs.sorted())
            for group in [b.left, b.right] {
                for (a, c) in zip(group, group.dropFirst()) {
                    let gap = frame(c, in: b.card).minX - frame(a, in: b.card).maxX
                    // A text label's cell keeps 2 pt of padding inside its frame: the text is still `buttonGap` from the button.
                    let pad: CGFloat = a is NSTextField ? 2 : 0
                    #expect(abs(gap + pad - SQDialogMetrics.buttonGap) < 0.5, "\(type(of: a)) -> \(type(of: c)) gap \(gap)")
                }
            }
        }
    }
}
