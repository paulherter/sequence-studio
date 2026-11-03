import Foundation
import SQCore
import SQUIKit

/// The app's design tokens for the portable UI. Surfaces and text come from SQUIKit's `AppearancePalette` (the same
/// resolve the Mac app runs); metrics, radii and the translucent fills mirror `Theme` (a Mac test checks they match).
public struct DrawTheme: Sendable, Equatable {
    public var palette: AppearancePalette
    /// Device pixels per point.
    public var scale: Float

    public init(settings: AppearanceSettings = .standard, scale: Float = 1) {
        palette = AppearancePalette.resolve(settings)
        self.scale = scale
    }

    /// Points to pixels.
    public func px(_ pt: Float) -> Float { (pt * scale).rounded() }

    static func color(_ c: PaletteColor) -> DrawColor { DrawColor(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, Float(c.a)) }

    // Surfaces and text
    public var canvas: DrawColor { Self.color(palette.canvas) }
    public var divider: DrawColor { Self.color(palette.divider) }
    public var titlebar: DrawColor { Self.color(palette.titlebar) }
    public var panel: DrawColor { Self.color(palette.panel) }
    public var content: DrawColor { Self.color(palette.content) }
    public var lane: DrawColor { Self.color(palette.lane) }
    public var timeline: DrawColor { Self.color(palette.timeline) }
    public var overlay: DrawColor { Self.color(palette.overlay) }
    public var label: DrawColor { Self.color(palette.label) }
    public var label2: DrawColor { Self.color(palette.label2) }
    public var label3: DrawColor { Self.color(palette.label3) }
    public var label4: DrawColor { Self.color(palette.label4) }
    /// Artifact surfaces: raised = secondary button, well = field/popup/check body (art.html `--raised`, `--well`).
    public var raised: DrawColor { DrawColor(hex: palette.isDark ? SQTokens.Hex.raisedDark : SQTokens.Hex.raisedLight) }
    public var raisedHover: DrawColor { DrawColor(hex: palette.isDark ? SQTokens.Hex.raisedHoverDark : SQTokens.Hex.raisedHoverLight) }
    public var pressed: DrawColor { DrawColor(hex: palette.isDark ? SQTokens.Hex.pressedDark : SQTokens.Hex.pressedLight) }
    public var well: DrawColor { DrawColor(hex: palette.isDark ? SQTokens.Hex.wellDark : SQTokens.Hex.wellLight) }
    /// Artifact rings and row states (`--hair`, `--hair2`, `--edge`, `--current`, `--hover`).
    public var hair: DrawColor { Self.color(palette.ink.withAlpha(palette.isDark ? SQTokens.Line.hairDark : SQTokens.Line.hairLight)) }
    public var hair2: DrawColor { Self.color(palette.ink.withAlpha(palette.isDark ? SQTokens.Line.hair2Dark : SQTokens.Line.hair2Light)) }
    public var edge: DrawColor { Self.color(palette.ink.withAlpha(palette.isDark ? SQTokens.Line.edgeDark : SQTokens.Line.edgeLight)) }
    public var current: DrawColor { Self.color(palette.ink.withAlpha(palette.isDark ? SQTokens.Line.currentDark : SQTokens.Line.currentLight)) }
    public var hover: DrawColor { Self.color(palette.ink.withAlpha(palette.isDark ? SQTokens.Line.hoverDark : SQTokens.Line.hoverLight)) }
    /// Row separator inside Effect Controls (art.html `--rowline`: black .30 dark, .07 light).
    public var rowLine: DrawColor { DrawColor.black.alpha(palette.isDark ? 0.30 : 0.07) }
    public var errText: DrawColor { Self.color(palette.errText) }
    public var accent: DrawColor { Self.color(palette.accent) }
    public var accentFill: DrawColor { Self.color(palette.accentFill) }

    // Translucent tokens (`Theme.inkFill` / `Theme.inkLine`)
    public func inkFill(_ a: Double) -> DrawColor { Self.color(palette.ink.withAlpha(palette.fillAlpha(a))) }
    public func inkLine(_ a: Double) -> DrawColor { Self.color(palette.ink.withAlpha(palette.lineAlpha(a))) }
    public var fill: DrawColor { inkFill(SQTokens.Alpha.fill) }
    public var fillHover: DrawColor { inkFill(SQTokens.Alpha.fillHover) }
    public var fillPressed: DrawColor { inkFill(SQTokens.Alpha.fillPressed) }
    public var separator: DrawColor { inkLine(SQTokens.Alpha.separator) }
    /// Menu separator and hover row (artifact `.msep` white .11, `.mi.cur` white .08).
    public var separatorStrong: DrawColor { hair2 }
    public var menuEdge: DrawColor { Self.color(palette.ink.withAlpha(palette.isDark ? SQTokens.Alpha.overlayEdge : 0.14)) }
    public var swatchEdge: DrawColor { Self.color(palette.ink.withAlpha(SQTokens.Alpha.swatchEdge)) }
    /// Line between list rows (`Theme.Separator.hairline`, G7): the `divider` tone.
    public var rowSeparator: DrawColor { divider }
    /// Row hover (ink 8 % in both appearances); the selected row is `selection`.
    public var rowHover: DrawColor { current }
    public var trackRowLine: DrawColor { inkLine(SQTokens.Alpha.trackRowLine) }
    public var trackHeaderLine: DrawColor { inkLine(SQTokens.Alpha.trackHeaderLine) }
    public var rulerLine: DrawColor { inkLine(SQTokens.Alpha.rulerLine) }
    public var rulerMinor: DrawColor { inkLine(SQTokens.Alpha.rulerMinor) }
    public var playhead: DrawColor { palette.isDark ? DrawColor.white.alpha(Float(SQTokens.Alpha.playhead)) : DrawColor(hex: SQTokens.Hex.playheadLight, alpha: Float(SQTokens.Alpha.playhead)) }
    public var monitorBackdrop: DrawColor { DrawColor(hex: SQTokens.Hex.monitorBackdrop) }
    /// This theme for text drawn on the always-dark monitor backdrop: in Light the label tones are the dark theme's.
    public var onViewer: DrawTheme {
        guard !palette.isDark else { return self }
        var d = self
        let dark = AppearancePalette.resolve(AppearanceSettings(mode: .dark))
        d.palette.label = dark.label; d.palette.label2 = dark.label2; d.palette.label3 = dark.label3
        return d
    }
    /// `Theme.Colors.viewer`: the picture well behind a preview (the Export sheet's preview box).
    public var viewer: DrawColor { DrawColor(hex: SQTokens.Hex.viewer) }
    /// Monitor overlays (`Theme.Colors.guide` / `viewerHUD` / `platformMock`; `field` is in Inspector/InspectorControls).
    public var guide: DrawColor { DrawColor.white.alpha(Float(SQTokens.Alpha.guide)) }
    public var viewerHUD: DrawColor { DrawColor.black.alpha(Float(SQTokens.Alpha.viewerHUD)) }
    public var platformMock: DrawColor { DrawColor.white.alpha(Float(SQTokens.Alpha.platformMock)) }
    /// Handles and outlines drawn over the picture (`Theme.OnPicture.stroke` / `shadow` / `guideSnap`).
    public var onPictureStroke: DrawColor { .white }
    public var onPictureShadow: DrawColor { DrawColor.black.alpha(Float(SQTokens.Alpha.onPictureShadow)) }
    public var guideSnap: DrawColor { DrawColor(hex: SQTokens.Hex.guideSnap) }
    /// Selected clips, snap line (DESIGN.md color roles).
    /// Artifact caption clip teal (art.html captions row), painted for every caption clip regardless of its label.
    public var captionClip: DrawColor { DrawColor(0.05, 0.54, 0.51) }
    public var yellow: DrawColor { DrawColor(hex: SQTokens.Hex.yellow) }
    public var onClip: DrawColor { .white }
    /// Transparency checkerboard grays and the neutral middle stop of the color ramps (`Theme.Palette.checker`).
    public static let checkerDark = DrawColor(0.30, 0.30, 0.30), checkerLight = DrawColor(0.45, 0.45, 0.45)
    public static let rampNeutral = DrawColor(0.54, 0.54, 0.54)

    /// A clip's body color for its label (`LabelColor.rgb`) and its edge (`Theme.lift`, 11 % toward white).
    public func clip(_ label: LabelColor) -> DrawColor { DrawColor(hex: label.rgb) }
    public func clipEdge(_ label: LabelColor) -> DrawColor { clip(label).lifted(0.11) }

    /// `Theme.Metrics` / `Theme.Spacing` / `Theme.Radius` in points.
    public enum Metrics {
        public static let topBar: Float = SQTokens.Metrics.topBar
        public static let statusBar: Float = SQTokens.Metrics.statusBar
        public static let panelHeader: Float = SQTokens.Metrics.panelHeader
        public static let trackV1: Float = SQTokens.Metrics.trackV1
        public static let trackA1: Float = SQTokens.Metrics.trackA1
        public static let trackOther: Float = SQTokens.Metrics.trackOther
        public static let trackHeader: Float = SQTokens.Metrics.trackHeader
        public static let capsule: Float = SQTokens.Metrics.capsule
        public static let monitorHeader: Float = SQTokens.Metrics.monitorHeader
        public static let monitorFooter: Float = SQTokens.Metrics.monitorFooter
        /// Listening volume strip under the audio meter: slider and Dim button.
        public static let monitorStrip: Float = SQTokens.Metrics.monitorStrip
        public static let monitorSliderMaxWidth: Float = SQTokens.Metrics.monitorSliderMaxWidth
        public static let monitorSliderHeight: Float = SQTokens.Metrics.monitorSliderHeight
        public static let monitorDimWidth: Float = SQTokens.Metrics.monitorDimWidth
        public static let monitorDimHeight: Float = SQTokens.Metrics.monitorDimHeight
        public static let scrubBar: Float = SQTokens.Metrics.scrubBar
        public static let sequenceTabs: Float = SQTokens.Metrics.sequenceTabs
        /// Time ruler over the tracks.
        public static let ruler: Float = SQTokens.Metrics.ruler
        /// The clip name band at the top of a clip (DESIGN.md: 13 pt).
        public static let clipNameBand: Float = SQTokens.Metrics.clipNameBand
        /// Gap between docked panel cards and around the workspace (`Theme.Spacing.paneDivider`).
        public static let paneDivider: Float = SQTokens.Metrics.paneDivider
    }
    public enum Spacing {
        public static let xxs: Float = SQTokens.Spacing.xxs, xs: Float = SQTokens.Spacing.xs, snug: Float = SQTokens.Spacing.snug
        public static let sm: Float = SQTokens.Spacing.sm, md: Float = SQTokens.Spacing.md, lg: Float = SQTokens.Spacing.lg
        public static let wide: Float = SQTokens.Spacing.wide, xl: Float = SQTokens.Spacing.xl, xxl: Float = SQTokens.Spacing.xxl
    }
    public enum Radius {
        public static let none: Float = SQTokens.Radius.none, panel: Float = SQTokens.Radius.panel, small: Float = SQTokens.Radius.small
        public static let control: Float = SQTokens.Radius.control, overlay: Float = SQTokens.Radius.overlay
        public static let menu: Float = SQTokens.Radius.menu, card: Float = SQTokens.Radius.card
    }
    /// Row and control heights in points (`Theme.Row`, `Theme.Dialog.buttonHeight`): compact 22, normal 24, large 28.
    public enum Height {
        public static let compact: Float = SQTokens.Height.compact, normal: Float = SQTokens.Height.normal, large: Float = SQTokens.Height.large
        /// Rows of the right-column lists (`Theme.Row.panelList`).
        public static let panelList: Float = SQTokens.Height.panelList
    }
    /// Type sizes in points (`Theme.Typography`: ladder 10 / 11 / 12 / 13 / 15 / 18; clip name is caption).
    public enum TypeSize {
        public static let caption: Float = SQTokens.TypeSize.caption, body: Float = SQTokens.TypeSize.body, list: Float = SQTokens.TypeSize.list
        public static let title: Float = SQTokens.TypeSize.title, heading: Float = SQTokens.TypeSize.heading
        public static let display: Float = SQTokens.TypeSize.display, clipName: Float = SQTokens.TypeSize.clipName
    }
}

extension DrawTheme {
    /// `Theme.Palette.marker`: one marker color per `MarkerColor` (ruler, markers list, marker Color popup dots).
    public static func marker(_ c: MarkerColor) -> DrawColor {
        switch c {
        case .green: DrawColor(hex: SQTokens.Hex.green)
        case .red: DrawColor(0.93, 0.30, 0.28)
        case .purple: DrawColor(0.62, 0.42, 0.90)
        case .orange: DrawColor(0.96, 0.58, 0.20)
        case .yellow: DrawColor(0.95, 0.82, 0.25)
        case .white: DrawColor(0.92, 0.92, 0.92)
        case .blue: DrawColor(0.30, 0.52, 0.95)
        case .cyan: DrawColor(0.28, 0.82, 0.88)
        }
    }
}

extension DrawColor {
    /// 0xRRGGBB, rounded; alpha is dropped (menu swatches and popup dots take opaque hex).
    public var rgbHex: UInt32 {
        func byte(_ v: Float) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
