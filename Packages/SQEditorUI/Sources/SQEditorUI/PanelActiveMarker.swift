import AppKit
import SQUIKit

/// The mark of the active (focused) panel (v9 `.panel.focus .tab[aria-selected]::after`): the 2 pt line under the selected
/// tab is the quiet `label3` normally and the accent while the panel has focus. One rule for every panel group.
public enum PanelActiveMarker {
    public static let thickness: CGFloat = 2

    public static func lineColor(active: Bool) -> NSColor { active ? Theme.Colors.accent : Theme.Colors.label3 }

    /// Where the line sits in a group whose tab strip is not shown (the Timeline's own sequence tabs, a panel's own header):
    /// at the group's top edge, or at the bottom of the header when it has one. `bounds` is the group, flipped (origin top-left).
    public static func lineFrame(in bounds: CGRect, headerHeight: CGFloat) -> CGRect {
        let inset = Theme.Spacing.sm
        let y = headerHeight > 0 ? headerHeight - thickness : 0
        return CGRect(x: inset, y: y, width: max(bounds.width - 2 * inset, 0), height: thickness)
    }
}

/// Which panel group shows the active mark, and how. One rule, applied by the shell's `PanelContainerView`; the
/// panel that is active is `focusedPanel` of the app controller, nothing else (not the selected sequence tab, not
/// the last panel that was ever used).
public enum PanelFocusRule {
    public enum Line: Equatable, Sendable {
        /// The group's tab strip draws its own underline (accent while focused, quiet otherwise).
        case none
        /// A strip-less group (Timeline, a panel's own header): the group's top line, accent only while focused.
        case accent
        /// The same line while the group is not focused: neutral gray, never accent.
        case quiet
    }

    public static func line(isFocused: Bool, stripShown: Bool) -> Line {
        if stripShown { return .none }
        return isFocused ? .accent : .quiet
    }

    /// The focused panel after the keyboard focus (first responder) moved into a view of `responderPanel`.
    /// A responder outside every panel (window, top bar, field editor on its way out) leaves the focus alone.
    public static func focus(afterResponderIn responderPanel: PanelID?, current: PanelID?) -> PanelID? {
        responderPanel ?? current
    }

    /// Whether the group showing `selected` is the focused one (exactly one group at a time).
    public static func isFocused(group selected: PanelID, focused: PanelID?) -> Bool { selected == focused }
}
