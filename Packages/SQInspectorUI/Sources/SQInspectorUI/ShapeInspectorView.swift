import AppKit
import SQCore

/// The Shape section of Controls: which outline the selected shape clip draws. Size, fill, stroke and corner radius
/// are the keyframable rows of its Shape effect below, so they are not repeated here. Rows on `ControlsGrid`.
@MainActor
public final class ShapeInspectorView: NSView {
    /// The user picked another outline.
    public var onKindChange: ((ShapeKind) -> Void)?

    let kindControl: SQSegmented
    private let hint = NSTextField(labelWithString: "Size and colors: Shape effect below")

    public override var isFlipped: Bool { true }

    public init() {
        let kinds = ShapeKind.allCases
        kindControl = SQSegmented(labels: kinds.map { _ in "" }, segmentWidth: 32)
        super.init(frame: .zero)
        for (i, k) in kinds.enumerated() {
            kindControl.images.append(Theme.symbol(Self.symbol(k), size: 12, label: k.title))
            kindControl.setToolTip(k.title, forSegment: i)
        }
        kindControl.target = self
        kindControl.action = #selector(kindChanged)
        kindControl.setAccessibilityLabel("Shape")
        kindControl.setContentHuggingPriority(.required, for: .horizontal)
        hint.font = Theme.Typography.body
        hint.textColor = Theme.Colors.label3
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.sqToolTip = "Size, fill, stroke and corner radius are rows of the Shape effect below, all keyframable."
        let stack = ControlsRows.stack([
            TextBlockRow(label: "Shape", controls: [kindControl, ControlsRows.spacer()]),
            TextBlockRow(label: nil, controls: [hint]),
        ])
        addSubview(stack)
        ControlsRows.pin(stack, in: self)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows `kind` without reporting a change.
    public func show(_ kind: ShapeKind) {
        kindControl.selectedSegment = ShapeKind.allCases.firstIndex(of: kind) ?? 0
    }

    @objc private func kindChanged() {
        let all = ShapeKind.allCases
        guard all.indices.contains(kindControl.selectedSegment) else { return }
        onKindChange?(all[kindControl.selectedSegment])
    }

    static func symbol(_ k: ShapeKind) -> SQIcon {
        switch k {
        case .rectangle: .shapeRectangle
        case .ellipse: .shapeEllipse
        case .line: .shapeLine
        case .arrow: .arrowRight
        }
    }
}

/// Helpers for a hosted Controls section whose body is a plain stack of grid rows (`TextBlockRow`).
@MainActor
enum ControlsRows {
    /// A vertical stack of full-width rows without spacing or insets (the rows carry the grid).
    static func stack(_ rows: [NSView]) -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 0
        s.translatesAutoresizingMaskIntoConstraints = false
        for r in rows { add(r, to: s) }
        return s
    }

    static func add(_ row: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    static func pin(_ stack: NSStackView, in view: NSView) {
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Takes the room a row's controls leave (a plain NSView: the layout probe skips it).
    static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    /// The control fills its row up to the trailing inset.
    static func fill(_ v: NSView) {
        v.setContentHuggingPriority(.init(2), for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
}
