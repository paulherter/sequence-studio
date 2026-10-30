import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The one column grid of the Controls column (Effect Controls) and every inspector row. All rows of all sections use
/// it at every panel width, so column edges, row heights and gaps are the same everywhere. Numbers: `Theme.Inspector`.
///
///     | inset | indent | toggle | gap | label | gap | value 0 | gap | value 1 | gap | ... | gap | tail | trailing |
///
/// A section header has no indent (`headerToggleX`, `headerLabelX`); the rows of an opened section sit one step
/// (`Theme.Inspector.rowIndent`) to the right of it, and a group header inside a section sits on the row edges.
///
/// Edges are outer bounds of the control in the column (button, field, swatch, checkbox), never the text inside it.
/// The keyframe lanes start where the column ends; a lane row has the y and height of its control row.
/// Portable (Windows too): the draw-list Controls panel places its rows with the same grid.
public struct ControlsGrid: Equatable, Sendable {
    /// The `Theme.Inspector` / `Theme.Row` numbers the grid is built from. `Theme` is AppKit, so off the Mac they are
    /// the literals at UI scale 1.
    /// shortcut: literals off the Mac, ControlsGridTokenTests checks they match `Theme`; upgrade when the tokens move to
    /// a portable file.
    public enum Tokens {
        public static let ringX: CGFloat = 8, toggleWidth: CGFloat = 14, columnGap: CGFloat = 6, nameWidth: CGFloat = 88
        public static let rowIndent: CGFloat = 12, valueWidth: CGFloat = 50, trailing: CGFloat = 12
        public static let resetWidth: CGFloat = 22, navigationWidth: CGFloat = 72, labelHeight: CGFloat = 14
        public static let rowHeight: CGFloat = 26, sectionGap: CGFloat = 4, controlHeight: CGFloat = 22
        public static let nameX = ringX + toggleWidth + columnGap
        public static let controlX = nameX + nameWidth + columnGap
        public static let controlColumnWidth = 3 * valueWidth + 2 * columnGap
    }
    #if canImport(AppKit)
    private typealias T = Theme.Inspector
    private static let rowControl = Theme.Row.control
    #else
    private typealias T = Tokens
    private static let rowControl = Tokens.controlHeight
    #endif

    /// Width of the row (the Controls column up to the divider).
    public var width: CGFloat
    public init(width: CGFloat) { self.width = width }

    // Fixed edges (independent of the width).
    /// Section header: chevron column and title, at the panel's inset.
    public static let headerToggleX = T.ringX
    public static let headerLabelX = T.nameX
    public static let headerToggleMidX = headerToggleX + toggleWidth / 2
    /// The step the rows of an opened section (and a group inside it) move right of their header.
    public static let rowIndent = T.rowIndent
    public static let toggleX = headerToggleX + rowIndent
    public static let toggleWidth = T.toggleWidth
    public static let toggleMidX = toggleX + toggleWidth / 2
    public static let gap = T.columnGap
    public static let labelX = headerLabelX + rowIndent
    public static let labelWidth = T.nameWidth
    public static let valueX = T.controlX + rowIndent
    public static let valueWidth = T.valueWidth
    /// Widest a control of a row grows (`Theme.Inspector.controlColumnWidth`), measured from `valueX`.
    public static let controlColumnWidth = T.controlColumnWidth
    /// Right edge of the control column (before the panel's trailing inset applies).
    public static let controlColumnMaxX = valueX + controlColumnWidth
    public static let trailing = T.trailing
    public static let resetWidth = T.resetWidth
    public static let navigationWidth = T.navigationWidth
    /// One nesting level (a group header inside a section): its chevron and title sit on the rows' toggle and label
    /// columns, one step right of the section header.
    public static let levelIndent = rowIndent

    // Heights.
    public static let rowHeight = T.rowHeight
    public static let headerHeight = T.rowHeight
    public static let sectionGap = T.sectionGap
    public static let controlHeight = rowControl
    public static let labelHeight = T.labelHeight

    /// Left edge of the n-th value column.
    public static func valueColumn(_ index: Int) -> CGFloat { valueX + CGFloat(index) * (valueWidth + gap) }

    // Width dependent edges.
    /// Right edge of the tail column and of every control that fills its row.
    public var tailMaxX: CGFloat { width - Self.trailing }
    public var resetX: CGFloat { tailMaxX - Self.resetWidth }
    /// The key navigation sits left of the reset slot, which every keyframable row reserves at the trailing edge.
    public var navigationX: CGFloat { resetX - Self.gap - Self.navigationWidth }
    /// Right edge of the values of a row that has key navigation in its tail.
    public var valueMaxX: CGFloat { navigationX - Self.gap }

    // Frames in a row `height` high.
    public func toggleFrame(height: CGFloat) -> CGRect { CGRect(x: Self.toggleX, y: 0, width: Self.toggleWidth, height: height) }
    /// The chevron of a section header.
    public func headerToggleFrame(height: CGFloat) -> CGRect { CGRect(x: Self.headerToggleX, y: 0, width: Self.toggleWidth, height: height) }
    /// A `size` square (checkbox, ring) centered in the toggle column.
    public func toggleBox(_ size: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: Self.toggleMidX - size / 2, y: ((height - size) / 2).rounded(), width: size, height: size)
    }
    /// The label, from the label column to `maxX` (default: the value column).
    public func labelFrame(height: CGFloat, maxX: CGFloat? = nil) -> CGRect {
        let end = (maxX ?? Self.valueX) - Self.gap
        return CGRect(x: Self.labelX, y: ((height - Self.labelHeight) / 2).rounded(), width: max(end - Self.labelX, 0), height: Self.labelHeight)
    }
    /// Frames `label` in the label column and keeps long names readable without widening the column or shrinking the font:
    /// the name takes `maxX` when the row has free room there (a row without a control passes `valueMaxX`), otherwise it is cut
    /// in the middle and an SQ tooltip shows the full name. Returns the frame it set.
    #if canImport(AppKit)
    @MainActor
    public func place(_ label: NSTextField, height: CGFloat, maxX: CGFloat? = nil) -> CGRect {
        label.lineBreakMode = .byTruncatingMiddle
        let natural = ceil(label.attributedStringValue.size().width)
        var frame = labelFrame(height: height)
        if let maxX, natural > frame.width {
            frame.size.width = min(natural, max(maxX - Self.labelX, frame.width))
        }
        label.frame = frame
        label.sqToolTip = Self.truncates(textWidth: natural, frameWidth: frame.width) ? label.stringValue : nil
        return frame
    }
    #endif
    /// Whether a name `textWidth` wide does not fit a label `frameWidth` wide (it gets the middle cut and the tooltip).
    public static func truncates(textWidth: CGFloat, frameWidth: CGFloat) -> Bool { textWidth > frameWidth + 0.5 }

    /// A control `width` wide and `controlHeight` high starting at `x`, centered in the row.
    public func controlFrame(x: CGFloat, width: CGFloat, height: CGFloat, controlHeight: CGFloat = ControlsGrid.controlHeight) -> CGRect {
        CGRect(x: x, y: ((height - controlHeight) / 2).rounded(), width: max(width, 0), height: controlHeight)
    }
    /// The n-th number field.
    public func valueFrame(_ index: Int, height: CGFloat) -> CGRect {
        controlFrame(x: Self.valueColumn(index), width: Self.valueWidth, height: height)
    }
    /// A control from the value column to `maxX` (default: the trailing inset), at most `maxWidth` wide.
    public func fillFrame(height: CGFloat, maxX: CGFloat? = nil, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGRect {
        controlFrame(x: Self.valueX, width: min((maxX ?? tailMaxX) - Self.valueX, maxWidth), height: height)
    }
    public func resetFrame(height: CGFloat) -> CGRect { CGRect(x: resetX, y: 0, width: Self.resetWidth, height: height) }
    public func navigationFrame(height: CGFloat) -> CGRect { CGRect(x: navigationX, y: 0, width: Self.navigationWidth, height: height) }
}

/// What one row puts into the grid's columns, in the row's own coordinates: the layout test reads it to prove that
/// every row of every section uses the same edges and gaps.
public struct ControlsRowProbe: Sendable {
    /// Chevron, animate toggle or checkbox in the toggle column.
    public var toggle: CGRect?
    public var label: CGRect?
    /// Outer bounds of the controls from the value column on, left to right.
    public var controls: [CGRect] = []
    /// Reset arrow, key navigation or chevron in the tail column.
    public var tail: CGRect?
    /// Nesting level of a header (`ControlsGrid.levelIndent` per level; 0 = section header).
    public var level = 0
    /// A row of icon groups and icon-led fields without a label: its first control starts in the label column
    /// (`ControlsGrid.labelX`) instead of the value column. Gaps and the trailing inset still follow the grid.
    public var fullWidth = false

    public init(toggle: CGRect? = nil, label: CGRect? = nil, controls: [CGRect] = [], tail: CGRect? = nil, level: Int = 0,
                fullWidth: Bool = false) {
        self.toggle = toggle; self.label = label; self.controls = controls; self.tail = tail; self.level = level
        self.fullWidth = fullWidth
    }
}

#if canImport(AppKit)
@MainActor
public protocol ControlsRowProbing: NSView {
    var rowProbe: ControlsRowProbe { get }
}
#endif
