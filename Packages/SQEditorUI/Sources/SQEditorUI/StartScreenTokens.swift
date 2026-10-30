import AppKit

/// Tokens of the start screen (design "Start Screen B", its own `.sq` scale: 13 px body, 8-12 px radii, 28 px rows).
/// The start screen uses these measurements, not the 11 pt editor scale. Colors come from Theme (Appearance setting);
/// `Theme.Colors.canvas` is the color between its panels.
extension Theme.Metrics {
    /// Left rail width, status bar height, gap and outer margin of the panels (8 px, the canvas shows through).
    public static let startRail: CGFloat = 252
    public static let startStatus: CGFloat = 28
    public static let startGap: CGFloat = 8
    /// Pane header (`.pth`) minimum height, Learn card height, list thumbnail, Home quick-size tile, Continue picture.
    public static let startPaneHeader: CGFloat = 56
    public static let startLearnCard: CGFloat = 64
    public static let startListThumb = NSSize(width: 40, height: 32)
    public static let startQuickTile: CGFloat = 52
    public static let startContinueThumb: CGFloat = 190
    public static let startTemplateThumb: CGFloat = 120
    /// Smallest card width of the Recent grid (four columns in the default window) and of the Learn grid.
    public static let startCardMin: CGFloat = 168
    public static let startLearnMin: CGFloat = 260
    /// Badge on a card picture (aspect, length): min height, 0.72 black.
    public static let startBadge: CGFloat = 20
    public static let startBadgeAlpha: CGFloat = 0.72
    /// Appearance popover width and its label / value columns.
    public static let startAppearanceWidth: CGFloat = 300
    public static let startAppearanceLabel: CGFloat = 80
    public static let startAppearanceValue: CGFloat = 36
    /// Room the traffic lights take at the left of the top bar.
    public static let startLights: CGFloat = 78
    /// Top bar (title bar with the search field) height.
    public static let startTop: CGFloat = 44
    /// Control and row heights (`--h-ctl`, `--h-sm`, `--h-row`), list row height (`.lrow`).
    public static let startControl: CGFloat = 28
    public static let startControlSmall: CGFloat = 24
    public static let startRow: CGFloat = 28
    public static let startListRow: CGFloat = 44
    /// Project card picture height (`.thumb`) and its inset inside the card.
    public static let startThumb: CGFloat = 150
    public static let startThumbInset: CGFloat = 4
    /// Search field width in the top bar.
    public static let startSearch: CGFloat = 260
    /// Spacing scale of the start screen (`--s1` ... `--s7`).
    public static let startS1: CGFloat = 4, startS2: CGFloat = 8, startS3: CGFloat = 12, startS4: CGFloat = 16
    public static let startS5: CGFloat = 20, startS6: CGFloat = 24, startS7: CGFloat = 32
    /// Horizontal padding of buttons and rows (`--pad-x`), icon gap (`--gap-ic`).
    public static let startPadX: CGFloat = 12
    public static let startIconGap: CGFloat = 8
    /// Default and minimum size of the start window (about Finder's).
    public static let startWindowSize = NSSize(width: 1100, height: 720)
    public static let startWindowMinSize = NSSize(width: 820, height: 520)
}

extension Theme.Radius {
    /// Start screen radii (`--r-ctl`, `--r-inner`, `--r-card`, `--r-menu`).
    public static let startControl: CGFloat = 8
    public static let startInner: CGFloat = 6
    public static let startCard: CGFloat = 12
    public static let startMenu: CGFloat = 10
}

extension Theme.Typography {
    /// Start screen type (`--fs-mini` 10, `--fs-cap` 11, `--fs-lab` 12, `--fs-body` 13, `--fs-h` 15, `--fs-title` 20),
    /// tabular digits.
    public static func start(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
    public static let startMini: CGFloat = 10, startCaption: CGFloat = 11, startLabel: CGFloat = 12
    public static let startBody: CGFloat = 13, startHeading: CGFloat = 15, startTitle: CGFloat = 20
}
