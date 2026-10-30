import AppKit
import SQCore

/// Design B tokens of floating layers outside the editor scope (`.menu`, `.mi`, `.mcap`, `.sheet`, `.alert`, `.popv`, `.win`).
/// The mock's menus and sheets sit outside `.ed`, so they use the non-editor scale: rows 28, radii 10 / 6, 12 pt text.
extension Theme {
    public enum Menu {
        public static let inset: CGFloat = 4
        public static let rowHeight: CGFloat = 24
        public static let rowPadLeft: CGFloat = 8
        public static let rowPadRight: CGFloat = 12
        public static let radius: CGFloat = Theme.Radius.menu
        public static let itemRadius: CGFloat = 6
        public static let minWidth: CGFloat = 160
        /// Caption row (`.mcap`): padding 6 top / 2 bottom, 11 pt semibold, text starts at x 30 (check column + gap).
        public static let captionHeight: CGFloat = 22
        nonisolated(unsafe) public static let font = Theme.Typography.ns(12, .regular)
        nonisolated(unsafe) public static let shortcutFont = Theme.Typography.ns(11, .regular)
        nonisolated(unsafe) public static let captionFont = Theme.Typography.ns(11, .semibold)
    }

    /// The modal shell (`SQModal`, windows proposal section 1): scrim over the whole main window, centered card.
    public enum Modal {
        /// Subtle black scrim over the main window. Never a gray or tinted fill: gray over the near-black UI lifted it to a
        /// flat bluish-gray area behind every pop-up (2026-10-17).
        public static let scrimAlpha: CGFloat = 0.35
        public static let scrimColor = Theme.black(scrimAlpha)
        /// The dim fades alpha-only over this long, in place at its final frame (never slides with the card).
        public static let dimFade: Double = 0
        /// Closing is faster than opening: card and dim fade out together.
        public static let dimFadeOut: Double = 0
        public static let radius: CGFloat = 14
        public static let headerHeight: CGFloat = 56
        public static let footerHeight: CGFloat = 68
        /// Body padding: 20 top and bottom, 24 left and right.
        public static let bodyPadV: CGFloat = 20
        public static let bodyPadH: CGFloat = 24
        /// Widths XS 360 (one or two fields), S 440 (alerts, prompts, forms), S with a list 480, M 600, L 860 x 640.
        public static let widthXS: CGFloat = 360
        /// Fixed sizes of the two small windows that are not modals (they sit beside the ladder, not on it).
        public static let exportProgressWindowSize = CGSize(width: 380, height: 148)
        public static let widthS: CGFloat = 440
        public static let widthSList: CGFloat = 480
        public static let widthM: CGFloat = 600
        public static let widthL: CGFloat = 860
        public static let heightL: CGFloat = 640
        /// Form label columns: 104 in S and M, 132 in L (Settings pages).
        public static let labelColumn: CGFloat = 104
        public static let labelColumnL: CGFloat = 132
        /// Gap between the card and the window edge that is kept free when the window is smaller than the card.
        public static let edgeMargin: CGFloat = 24
        /// Card shadow: a tight contact shadow only. The design's wide 0 24 60 at 55 % blur read as a second dark layer around
        /// the card on top of the scrim (2026-10-21); the scrim alone dims the window. `shadowRadius` is the CALayer radius.
        public static let shadowAlpha: CGFloat = 0.28
        public static let shadowOffsetY: CGFloat = 6
        public static let shadowRadius: CGFloat = 10
    }

    /// Sheets and alerts (`.sheet`, `.sh-head`, `.form`, `.sh-foot`, `.alert`): card radius 14 on `panel`.
    public enum Sheet {
        public static let radius: CGFloat = 14
        public static let headerHeight: CGFloat = 56
        public static let footerHeight: CGFloat = 68
        public static let sidePad: CGFloat = 20
        public static let formRowGap: CGFloat = 12
        public static let labelColumn: CGFloat = 104
        public static let labelGap: CGFloat = 16
        public static let controlHeight: CGFloat = 28
        public static let buttonRadius: CGFloat = 8
        public static let alertWidth: CGFloat = 400
        nonisolated(unsafe) public static let titleFont = Theme.Typography.ns(15, .semibold)
        nonisolated(unsafe) public static let subFont = Theme.Typography.ns(12, .regular)
        nonisolated(unsafe) public static let buttonFont = Theme.Typography.ns(12, .medium)
        nonisolated(unsafe) public static let alertTitleFont = Theme.Typography.ns(13, .semibold)
    }
}
