import AppKit

/// Numbers of the board `Dialogs` (docs/design-source/sq.css `.dlg`, `.dh`, `.df`, gen_frags.py `dlg()`).
/// Missing as Theme tokens (reported): dialog radius 14, dialog button height 26.
public enum SQDialogMetrics {
    public static let radius: CGFloat = Theme.Dialog.cardRadius
    /// Alert width: the S modal (440); sheets pass their own width.
    public static let defaultWidth: CGFloat = Theme.Modal.widthS
    public static let sidePad: CGFloat = Theme.Sheet.sidePad
    /// Header: padding 18 top / 12 bottom, 8 between title and note, note on a 16 pt line.
    public static let headerTop: CGFloat = 20
    public static let headerBottom: CGFloat = 12
    public static let headerGap: CGFloat = 8
    public static let noteLine: CGFloat = 16
    public static let titleLine: CGFloat = 13
    /// Footer: 56 high, 8 below the content, buttons 26 high, padding 16, 8 apart.
    public static let footerHeight: CGFloat = Theme.Sheet.footerHeight
    /// Alert footer: buttons sit on the card (no band), 20 below.
    public static let alertFooterHeight: CGFloat = Theme.Dialog.buttonHeight + Theme.Sheet.sidePad
    public static let footerGap: CGFloat = 8
    public static let buttonHeight: CGFloat = Theme.Dialog.buttonHeight
    public static let buttonPadding: CGFloat = 14
    public static let buttonGap: CGFloat = 8
    /// Form rows (`.dlg .row`): 28 high, label column 100 (190 for radio rows, 150 for the slider rows with long labels).
    public static let rowHeight: CGFloat = Theme.Sheet.controlHeight
    /// Label column 104 + 16 gap, labels right aligned (`.form`).
    public static let labelWidth: CGFloat = Theme.Sheet.labelColumn
    public static let labelGap: CGFloat = Theme.Sheet.labelGap
    public static let controlGap: CGFloat = 8
    /// Number field with a unit after it (board: `fld` 64-72 wide + `unit`).
    public static let unitFieldWidth: CGFloat = 72
    /// Body of an L modal (860 x 640 card): what the 56 header, the 68 footer and the gap `cardContent` leaves above the footer
    /// (`sidePad`) do not take. A body of this height makes the card exactly `Theme.Modal.heightL`.
    public static let lBodyHeight: CGFloat = Theme.Modal.heightL - Theme.Modal.headerHeight - Theme.Modal.footerHeight - Theme.Sheet.sidePad
    public static let checkRowHeight: CGFloat = 24
    public static let popupRowPad: CGFloat = 0
    public static let fieldRowBottom: CGFloat = 0

    /// Insets with the same `side` left and right (the card's 16 pt edge by default).
    public static func insets(_ top: CGFloat, _ bottom: CGFloat, side: CGFloat = sidePad) -> NSEdgeInsets {
        NSEdgeInsets(top: top, left: side, bottom: bottom, right: side)
    }
}

/// Card look shared by `SQDialog` and `SQModalSheet` (design B `.sheet`): `panel` fill, radius 14, .5 px white .14 edge (the shadowPop ring).
@MainActor
enum SQDialogStyle {
    static func styleCard(_ layer: CALayer?) {
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        layer?.cornerRadius = SQDialogMetrics.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Theme.Overlay.edgeWidth
        layer?.borderColor = Theme.Colors.overlayEdge.cgColor
        layer?.masksToBounds = true
    }
}

/// Content of a dialog in board layout: rows stacked edge to edge (each row carries its own 16 pt inset).
/// Assign it as `SQDialog.accessoryView`; the dialog stretches it to the card width.
@MainActor
public final class SQDialogForm: NSStackView {
    public init(rows: [NSView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Theme.Sheet.formRowGap
        distribution = .fill
        translatesAutoresizingMaskIntoConstraints = false
        for r in rows {
            addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }
}

extension SQDialog {
    private static func labelText(_ title: String) -> NSTextField {
        let l = NSTextField(labelWithString: SQL10n.string(title))
        l.font = Theme.Menu.font
        l.textColor = Theme.Colors.label2
        l.alignment = .right
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    /// Plain text (rows inside a form): `note` is 11 `label2` on a 16 pt line, otherwise 11 `label`.
    public static func formText(_ text: String, note: Bool = true, top: CGFloat = 0, bottom: CGFloat = 0) -> NSView {
        let text = SQL10n.string(text)
        let m = SQDialogMetrics.self
        let l = NSTextField(wrappingLabelWithString: text)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = m.noteLine
        p.maximumLineHeight = m.noteLine
        l.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: Theme.Sheet.subFont, .foregroundColor: note ? Theme.Colors.label2 : Theme.Colors.label,
            .baselineOffset: note ? 2 : 0, .paragraphStyle: p])
        l.isSelectable = false
        l.maximumNumberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return pad(l, NSEdgeInsets(top: top, left: m.sidePad, bottom: bottom, right: m.sidePad))
    }

    /// Wraps `v` with insets; the view stretches horizontally.
    public static func pad(_ v: NSView, _ insets: NSEdgeInsets, height: CGFloat? = nil) -> NSView {
        let h = NSView()
        h.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        h.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: h.leadingAnchor, constant: insets.left),
            v.trailingAnchor.constraint(equalTo: h.trailingAnchor, constant: -insets.right),
            v.topAnchor.constraint(equalTo: h.topAnchor, constant: insets.top),
            v.bottomAnchor.constraint(equalTo: h.bottomAnchor, constant: -insets.bottom),
        ])
        if let height { h.heightAnchor.constraint(equalToConstant: height).isActive = true }
        return h
    }

    /// "Label [control …]" row (board `.row`): 28 high, label left in a column of `labelWidth` (`label2`), controls fill the
    /// rest to the 16 pt edge, 8 apart, centered. Controls that should not grow need a fixed width or high hugging.
    public static func formRow(_ title: String, _ controls: [NSView], labelWidth: CGFloat = SQDialogMetrics.labelWidth,
                               trailing: CGFloat = SQDialogMetrics.sidePad) -> NSView {
        let controls = withUnits(controls)
        let m = SQDialogMetrics.self
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: m.rowHeight).isActive = true
        let l = labelText(title)
        row.addSubview(l)
        let s = NSStackView(views: controls)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.distribution = .fill
        s.spacing = m.controlGap
        s.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(s)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: m.sidePad),
            l.widthAnchor.constraint(equalToConstant: labelWidth),
            l.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            s.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: m.sidePad + labelWidth + m.labelGap),
            s.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -trailing),
            s.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        for c in controls { c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        return row
    }

    public static func formRow(_ title: String, _ control: NSView, labelWidth: CGFloat = SQDialogMetrics.labelWidth,
                               trailing: CGFloat = SQDialogMetrics.sidePad) -> NSView {
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return formRow(title, [control], labelWidth: labelWidth, trailing: trailing)
    }

    /// Units after number fields (board `fld` + `unit`), the one place that applies the rule to every dialog row: a `ScrubField`
    /// with `unitOutside` and a unit gets an `SQUnitLabel` after it, `controlGap` from the capsule's outline, and a fixed
    /// `SQDialogMetrics.unitFieldWidth` unless the caller gave it a width, so rows with and without units start at one edge.
    /// A `NumericSlider` draws its own unit and is only switched to `unitOutside`.
    static func withUnits(_ controls: [NSView]) -> [NSView] {
        var out: [NSView] = []
        for c in controls {
            out.append(c)
            if let slider = c as? NumericSlider { slider.unitOutside = true; continue }
            guard let f = c as? ScrubField, f.unitOutside, !f.unit.isEmpty else { continue }
            if !f.constraints.contains(where: { $0.firstAttribute == .width && $0.secondItem == nil }) {
                f.setContentHuggingPriority(.required, for: .horizontal)
                f.widthAnchor.constraint(equalToConstant: SQDialogMetrics.unitFieldWidth).isActive = true
                let spacer = NSView()
                spacer.setContentHuggingPriority(.init(1), for: .horizontal)
                out.append(SQUnitLabel(f.unit)); out.append(spacer)
            } else {
                out.append(SQUnitLabel(f.unit))
            }
        }
        return out
    }

    /// Naming row (board `name()`): field 22 high, 16 inset, 4 below.
    public static func fieldRow(_ field: NSView) -> NSView {
        let m = SQDialogMetrics.self
        return pad(field, m.insets(0, m.fieldRowBottom))
    }

    /// Popup on its own (board `popl()`): 4 above and below, 16 inset, full width.
    public static func popupRow(_ popup: NSView) -> NSView {
        let m = SQDialogMetrics.self
        return pad(popup, NSEdgeInsets(top: m.popupRowPad, left: m.sidePad, bottom: m.popupRowPad, right: m.sidePad))
    }

    /// Check box row (board `chk()`): 24 high, 16 inset.
    public static func checkRow(_ box: NSView) -> NSView {
        let m = SQDialogMetrics.self
        let h = NSView()
        h.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        h.addSubview(box)
        NSLayoutConstraint.activate([
            h.heightAnchor.constraint(equalToConstant: m.checkRowHeight),
            box.leadingAnchor.constraint(equalTo: h.leadingAnchor, constant: m.sidePad),
            box.trailingAnchor.constraint(lessThanOrEqualTo: h.trailingAnchor, constant: -m.sidePad),
            box.centerYAnchor.constraint(equalTo: h.centerYAnchor),
        ])
        return h
    }

    /// Slider row (board `srow()`): label 100 (or `labelWidth`), slider fills, 12 gap, value field `fieldWidth` wide.
    public static func sliderRow(_ title: String, slider: NSView, field: NSView, labelWidth: CGFloat = SQDialogMetrics.labelWidth,
                                 fieldWidth: CGFloat = 72) -> NSView {
        let row = formRow(title, [slider, field], labelWidth: labelWidth)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        if let s = row.subviews.last as? NSStackView { s.spacing = 12 }
        return row
    }

    /// Radio row (board `rrow()`): the radio with its label in a 190 column, the field fills the rest.
    public static func radioRow(_ radio: NSView, field: NSView, labelWidth: CGFloat = 190) -> NSView {
        let m = SQDialogMetrics.self
        var field = field
        let parts = withUnits([field])
        if parts.count > 1 {
            let s = NSStackView(views: parts)
            s.orientation = .horizontal; s.alignment = .centerY; s.spacing = m.controlGap
            field = s
        }
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: m.rowHeight).isActive = true
        radio.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addSubview(radio)
        row.addSubview(field)
        NSLayoutConstraint.activate([
            radio.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: m.sidePad),
            radio.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: m.sidePad + labelWidth + m.labelGap),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -m.sidePad),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }
}

/// Title or note of a dialog: title 13 semibold `label`, note 11 `label2` on a 16 pt line. `text` can change later.
@MainActor
public final class SQDialogText: NSTextField {
    public enum Kind: Sendable { case title, note }
    private let kind: Kind

    public init(_ kind: Kind, _ text: String = "", width: CGFloat) {
        self.kind = kind
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        usesSingleLineMode = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        preferredMaxLayoutWidth = width
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        self.text = text
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public var text: String {
        get { stringValue }
        set {
            let newValue = SQL10n.string(newValue)
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byWordWrapping
            let lh = kind == .note ? SQDialogMetrics.noteLine : SQDialogMetrics.titleLine
            p.minimumLineHeight = lh; p.maximumLineHeight = lh
            attributedStringValue = NSAttributedString(string: newValue, attributes: [
                .font: kind == .title ? Theme.Sheet.alertTitleFont : Theme.Sheet.subFont,
                .foregroundColor: kind == .title ? Theme.Dialog.titleColor : Theme.Dialog.noteColor,
                // AppKit seats text in a fixed line box differently from CSS: measured against the board, title 1 pt high, note 2 pt low.
                .baselineOffset: kind == .title ? -1 : 2,
                .paragraphStyle: p])
        }
    }
}

extension SQDialog {
    /// Footer row (board `.df`): 56 high, `left` buttons at the left edge, `right` buttons right aligned (8 apart), centered.
    public static func footerRow(left: [NSView], right: [NSView], band: Bool = true) -> NSView {
        let m = SQDialogMetrics.self
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: left + [spacer] + right)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = m.buttonGap
        row.edgeInsets = m.insets(0, band ? 0 : m.sidePad)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = band ? .centerY : .top
        row.heightAnchor.constraint(equalToConstant: band ? m.footerHeight : m.alertFooterHeight).isActive = true
        guard band else { return row }
        // `.sh-foot`: titlebar fill band under the form.
        let bandView = SQDialogFooterBand()
        bandView.translatesAutoresizingMaskIntoConstraints = false
        bandView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bandView.leadingAnchor), row.trailingAnchor.constraint(equalTo: bandView.trailingAnchor),
            row.topAnchor.constraint(equalTo: bandView.topAnchor), row.bottomAnchor.constraint(equalTo: bandView.bottomAnchor),
        ])
        return bandView
    }

    /// A card of a 56 high sheet header with `title` and `body` below it, no footer (a body that brings its own button bar,
    /// like Card Import). Returns the card of its fitting size, for `SQModalSheet`.
    public static func headerCard(title: String, body: NSView, width: CGFloat) -> NSView {
        let m = SQDialogMetrics.self
        let t = SQDialogText(.title, title, width: width - m.sidePad * 2)
        let header = NSStackView(views: [t])
        header.orientation = .vertical
        header.alignment = .leading
        header.translatesAutoresizingMaskIntoConstraints = false
        header.edgeInsets = m.insets(Theme.Spacing.lg, Theme.Spacing.lg)
        let top = sheetHeader(header)
        body.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [top, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for r in [top, body] { r.widthAnchor.constraint(equalToConstant: width).isActive = true }
        let card = SQDialogCardView()
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        card.layoutSubtreeIfNeeded()
        return card
    }

    /// `header` inside a container of at least `Theme.Modal.headerHeight`, vertically centered.
    static func sheetHeader(_ header: NSStackView) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(header)
        let minHeight = box.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Modal.headerHeight)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: box.leadingAnchor), header.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            header.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            header.topAnchor.constraint(greaterThanOrEqualTo: box.topAnchor), header.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor),
            minHeight,
        ])
        return box
    }

    /// The card of a dialog: header (padding 18/16/12, 8 between title and note), `body` edge to edge, 8, footer.
    /// Returns a card view of its fitting size (use as a `SQModalSheet` content view).
    public static func cardContent(title: NSView?, note: NSView?, body: NSView?, footer: NSView, width: CGFloat) -> NSView {
        let m = SQDialogMetrics.self
        let header = NSStackView(views: [title, note].compactMap { $0 })
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = m.headerGap
        header.translatesAutoresizingMaskIntoConstraints = false
        header.edgeInsets = NSEdgeInsets(top: m.headerTop, left: m.sidePad, bottom: m.headerBottom, right: m.sidePad)
        var rows: [NSView] = [header]
        if footer is SQDialogFooterBand {
            // Sheet header (`.sh-head`): at least 56 high, content centered. An alert (no band) keeps its own padding.
            rows[0] = sheetHeader(header)
        }
        if let body { rows.append(body) }
        rows.append(footer)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(footer is SQDialogFooterBand ? m.sidePad : m.footerGap, after: rows[rows.count - 2])
        for r in rows { r.widthAnchor.constraint(equalToConstant: width).isActive = true }
        let card = SQDialogCardView()
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        card.layoutSubtreeIfNeeded()
        return card
    }
}

/// Footer band of a sheet (`.sh-foot`): `titlebar` fill, full card width.
final class SQDialogFooterBand: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.titlebar.setFill()
        bounds.fill()
    }
}
