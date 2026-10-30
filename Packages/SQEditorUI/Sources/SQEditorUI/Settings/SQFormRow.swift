import AppKit
import SQUIKit

/// The one form row of the L modals (windows proposal section 4): label column 132 right-aligned (`Theme.Modal.labelColumnL`),
/// 16 gap, the control on the left edge of the control column, a unit 8 behind it, help text under the control (max 440 wide).
/// A row is 28 high at least; a control that stacks lines (a list, the Duck Timing grid) grows it and the label stays on the
/// first line.
@MainActor
public enum SQFormRow {
    /// Help text never runs wider than this.
    public static let helpMaxWidth: CGFloat = 440
    /// Height of the first line of a row (controls are centered in it).
    public static let lineHeight: CGFloat = Theme.Sheet.controlHeight
    /// Gap between the label column and the control column.
    public static let labelGap: CGFloat = Theme.Sheet.labelGap
    /// Distance between two rows.
    public static let rowGap: CGFloat = Theme.Sheet.formRowGap
    /// Gap between a control and its unit, and between controls in one line.
    public static let controlGap: CGFloat = Theme.Spacing.sm

    /// x of the control column inside a row (label column plus gap).
    public static func controlX(labelWidth: CGFloat = Theme.Modal.labelColumnL) -> CGFloat { labelWidth + labelGap }

    /// A row: `controls` in one line (8 apart), `help` under them. `title` empty keeps the column free (a second line of
    /// the row above, e.g. the cache size under the cache path).
    public static func row(_ title: String, _ controls: [NSView], help: String? = nil, extra: [NSView] = [],
                           labelWidth: CGFloat = Theme.Modal.labelColumnL) -> NSView {
        let line = NSStackView(views: controls)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = controlGap
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(greaterThanOrEqualToConstant: lineHeight).isActive = true
        for c in controls where !(c is NSTextField) { c.setContentHuggingPriority(.defaultHigh, for: .horizontal) }

        var column: [NSView] = [line] + extra
        if let help, !help.isEmpty { column.append(helpLabel(SQL10n.string(help))) }
        let stack = NSStackView(views: column)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: SQL10n.string(title))
        label.font = Theme.Typography.body
        label.textColor = Theme.Colors.label2
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            label.centerYAnchor.constraint(equalTo: host.topAnchor, constant: lineHeight / 2),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: controlX(labelWidth: labelWidth)),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    public static func row(_ title: String, _ control: NSView, help: String? = nil, extra: [NSView] = [],
                           labelWidth: CGFloat = Theme.Modal.labelColumnL) -> NSView {
        row(title, [control], help: help, extra: extra, labelWidth: labelWidth)
    }

    /// Group caption (`cap`): 11 semibold `label3`, starts at the control column, 8 above the next row.
    public static func caption(_ text: String, labelWidth: CGFloat = Theme.Modal.labelColumnL) -> NSView {
        let l = NSTextField(labelWithString: SQL10n.string(text))
        l.font = Theme.Typography.captionStrong
        l.textColor = Theme.Colors.label3
        l.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: controlX(labelWidth: labelWidth)),
            l.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor),
            l.topAnchor.constraint(equalTo: host.topAnchor, constant: Theme.Spacing.sm),
            l.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.heightAnchor.constraint(equalToConstant: Theme.Row.list + Theme.Spacing.sm),
        ])
        return host
    }

    /// Unit text behind a field ("frames", "seconds", "ms").
    public static func unit(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.Typography.body
        l.textColor = Theme.Colors.label3
        return l
    }

    /// Width of a number capsule in a Settings row (board `fld(.., 72)`), the same for every row so a page has one field edge.
    public static let numberWidth: CGFloat = SQDialogMetrics.unitFieldWidth

    /// A row with a number field and its unit after the capsule (shared dialog rule: `SQUnitLabel`, `controlGap` from the
    /// outline). `note` is a second, plain unit-style text behind the unit ("· 0 means 1 second"). The field gets
    /// `numberWidth`; give it `width: nil` in `SQDialog.makeNumberField`.
    public static func numberRow(_ title: String, field: ScrubField, unit: String, note: String? = nil, help: String? = nil) -> NSView {
        width(field, numberWidth)
        var controls: [NSView] = [field, SQUnitLabel(unit)]
        if let note { controls.append(Self.unit(note)) }
        return row(title, controls, help: help)
    }

    /// Titled number fields in a grid: title, capsule (`numberWidth`), unit. The unit is the field's own (`ScrubField.unit`)
    /// when it has `unitOutside`, so the Duck Timing grid and every other grid share the rule.
    public static func unitGrid(_ fields: [(title: String, field: NSView)]) -> NSGridView {
        let grid = NSGridView(views: fields.map { title, field in
            width(field, numberWidth)
            let unit = (field as? ScrubField).flatMap { $0.unitOutside && !$0.unit.isEmpty ? $0.unit : nil } ?? ""
            return [Self.unit(title), field, SQUnitLabel(unit)]
        })
        grid.columnSpacing = controlGap
        grid.rowSpacing = Theme.Spacing.sm
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .leading
        return grid
    }

    /// Wrapping help text, 11 `label3`, never wider than `helpMaxWidth`.
    public static func helpLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Theme.Typography.body
        l.textColor = Theme.Colors.label3
        l.isSelectable = false
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = helpMaxWidth
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(lessThanOrEqualToConstant: helpMaxWidth).isActive = true
        return l
    }

    /// Fixes the width of a control (popups 180, small popups 120, number fields 72).
    @discardableResult
    public static func width(_ control: NSView, _ w: CGFloat) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: w).isActive = true
        return control
    }

    /// The rows of a page, stacked `rowGap` apart; the stack fills the width of its container.
    public static func page(_ rows: [NSView]) -> NSStackView {
        let s = NSStackView(views: rows)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = rowGap
        s.translatesAutoresizingMaskIntoConstraints = false
        for r in rows { r.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        return s
    }
}
