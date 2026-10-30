import CoreGraphics

/// Window-shell sizes from the design boards (Main / Color / Parts "Panel parts"), 1 px = 1 pt.
/// Bar heights are the Theme tokens; the shell-only sizes (tab capsule, top-bar controls) live here.
public enum ShellMetrics {
    /// Top bar (sq.css `.top`): 52 pt, no divider line.
    public static let topBar: CGFloat = Theme.Metrics.topBar
    /// Panel header / tab strip (sq.css `.ph`), including its 1 pt separator.
    public static let panelHeader: CGFloat = Theme.Row.panelHeader
    /// Tab capsule in a panel header.
    public static let tabHeight: CGFloat = 22
    /// Controls in the top bar (segment, workspace popup, Export): 28 pt (v9 `--h-ctl`).
    public static let topControl: CGFloat = 28
    /// Gap between the top bar's groups (v9 `.top` gap 12).
    public static let topGap: CGFloat = 12
    /// Top bar padding (v9 `.top`: 0 12 0 16) and the window buttons (12 pt circles, 8 apart).
    public static let topLeading: CGFloat = 16
    public static let topTrailing: CGFloat = 12
    public static let windowLight: CGFloat = 12
    public static let windowLightGap: CGFloat = 8
    /// Status bar padding and gap between its texts (v9 `.status`: padding 0 16, gap 16), and the save dot.
    public static let statusPad: CGFloat = 16
    public static let statusDot: CGFloat = 6
    /// Icon in a top bar segment (v9 `.seg .i`: 14).
    public static let pageIcon: CGFloat = 14
    /// Layout popup "Editing – PC" in the top bar.
    public static let layoutPopupWidth: CGFloat = 110
    /// Status bar.
    public static let statusBar: CGFloat = Theme.Metrics.statusBar
}
