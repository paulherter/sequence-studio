import AppKit

/// Design tokens from docs/DESIGN.md. Dark appearance only. All colors are fixed sRGB values
/// (deterministic, no dynamic system colors), so custom-drawn views look the same everywhere.
public enum Theme {
    /// Builds an sRGB color from 0xRRGGBB and an alpha.
    public static func hex(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
    static func white(_ alpha: CGFloat) -> NSColor { hex(0xFFFFFF, alpha: alpha) }
    static func black(_ alpha: CGFloat) -> NSColor { hex(0x000000, alpha: alpha) }

    public enum Colors {
        // Surfaces
        public static let titlebar = Theme.hex(0x1F1F1F)
        public static let panel = Theme.hex(0x1A1A1A)
        public static let content = Theme.hex(0x161616)
        public static let rowAlt = Theme.white(0.025)
        public static let viewer = Theme.hex(0x0C0C0C)
        public static let timeline = Theme.hex(0x121212)
        public static let lane = Theme.hex(0x151515)
        public static let divider = Theme.hex(0x000000)
        public static let separator = Theme.white(0.075)
        // Text
        public static let label = Theme.white(0.86)
        public static let label2 = Theme.white(0.62)
        public static let label3 = Theme.white(0.46)
        // Fills and controls
        public static let fill = Theme.white(0.11)
        public static let fill2 = Theme.white(0.06)
        public static let fillHover = Theme.white(0.16)
        public static let fillPressed = Theme.white(0.22)
        public static let field = Theme.black(0.28)
        public static let fieldEdge = Theme.white(0.10)
        public static let selection = Theme.white(0.10)
        // Accent
        public static let accent = Theme.hex(0x0A84FF)
        public static let accentFill = Theme.hex(0x0A6CF0)
        public static let accentRing = Theme.hex(0x0A84FF, alpha: 0.45)
        public static let accentTint = Theme.hex(0x0A84FF, alpha: 0.22)
        // Status
        public static let red = Theme.hex(0xFF453A)
        public static let green = Theme.hex(0x30D158)
        public static let yellow = Theme.hex(0xFFD60A)
        // Clips
        public static let clipVideo = Theme.hex(0x3D67B8)
        public static let clipVideoEdge = Theme.hex(0x6F95DC)
        public static let clipAudio = Theme.hex(0x2F6B3A)
        public static let clipAudioEdge = Theme.hex(0x4E9A5A)
        public static let clipAudioWave = Theme.hex(0x9FD98A)
        public static let clipNest = Theme.hex(0x8A6320)
        public static let clipNestEdge = Theme.hex(0xC29445)
        public static let clipTitle = Theme.hex(0x9C3F79)
        public static let clipTitleEdge = Theme.hex(0xCF6AA9)
        public static let clipCaption = Theme.hex(0x6A4DBD)
        public static let clipCaptionEdge = Theme.hex(0x9C82E4)
        public static let clipShade = Theme.black(0.22)
        public static let onClip = Theme.hex(0xFFFFFF)
        public static let clipSelect = Theme.hex(0xFFFFFF)
        /// Snap indicator line (timeline and playhead drags).
        public static let snapLine = Theme.hex(0xFFD60A)
        // Timeline furniture
        public static let playhead = Theme.white(0.92)
        public static let keyframe = Theme.hex(0xD6D6D6)
        public static let marker = Theme.hex(0xFF9F0A)
        public static let range = Theme.white(0.07)
        public static let rangeEdge = Theme.white(0.55)
        // Graph curves
        public static let curveX = Theme.hex(0xFF9F0A)
        public static let curveY = Theme.hex(0x64D2FF)
        // Overlays
        public static let menu = Theme.hex(0x222222, alpha: 0.95)
        public static let scrim = Theme.black(0.38)
    }

    /// Tabular digits everywhere (DESIGN.md: numbers use monospaced digits).
    public enum Fonts {
        /// 10 regular: ruler, table headers, status bar.
        nonisolated(unsafe) public static let mini = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        /// 11 regular: default UI text.
        nonisolated(unsafe) public static let small = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        /// 11 weight 500: names.
        nonisolated(unsafe) public static let smallName = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        /// 13 regular: window title, dialogs, menus.
        nonisolated(unsafe) public static let body = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        /// 13 semibold: titles and section headers (the only semibold use).
        nonisolated(unsafe) public static let bodyTitle = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        /// 18 light: viewer timecode.
        nonisolated(unsafe) public static let timecode = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .light)
        /// 9.5 regular: custom-drawn clip names.
        nonisolated(unsafe) public static let clip = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        /// 9 regular: meter scale.
        nonisolated(unsafe) public static let meter = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    }

    /// Spacing scale in pt.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        /// Icon to label.
        public static let iconToLabel: CGFloat = 6
        public static let paneDivider: CGFloat = 1
        public static let scale: [CGFloat] = [xxs, xs, sm, md, lg, xl]
    }

    /// Corner radii in pt. Capsules (tabs, buttons, search, toolbar groups) use `capsule(forHeight:)`.
    public enum Radius {
        public static let small: CGFloat = 3
        public static let clip: CGFloat = 4
        public static let field: CGFloat = 5
        public static let row: CGFloat = 6
        public static let card: CGFloat = 8
        public static let menu: CGFloat = 10
        public static let popover: CGFloat = 12
        public static let window: CGFloat = 16
        public static let scale: [CGFloat] = [small, clip, field, row, card, menu, popover, window]
        public static func capsule(forHeight h: CGFloat) -> CGFloat { h / 2 }
    }

    public enum Metrics {
        public static let toolbar: CGFloat = 52
        public static let statusBar: CGFloat = 22
        public static let panelHeader: CGFloat = 30
        public static let effectControlsRow: CGFloat = 24
        public static let listRow: CGFloat = 22
        public static let controlHeight: CGFloat = 20
        public static let pushButton: CGFloat = 22
        // Tracks
        public static let trackV1: CGFloat = 32
        public static let trackA1: CGFloat = 26
        public static let trackOther: CGFloat = 20
        public static let trackHeader: CGFloat = 124
        public static let toolColumn: CGFloat = 38
    }
}
