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
    public var accent: DrawColor { Self.color(palette.accent) }
    public var accentFill: DrawColor { Self.color(palette.accentFill) }

    // Translucent tokens (`Theme.inkFill` / `Theme.inkLine`)
    public func inkFill(_ a: Double) -> DrawColor { Self.color(palette.ink.withAlpha(palette.fillAlpha(a))) }
    public func inkLine(_ a: Double) -> DrawColor { Self.color(palette.ink.withAlpha(palette.lineAlpha(a))) }
    public var fill: DrawColor { inkFill(0.11) }
    public var fillHover: DrawColor { inkFill(0.16) }
    public var fillPressed: DrawColor { inkFill(0.22) }
    public var separator: DrawColor { inkLine(0.065) }
    public var trackRowLine: DrawColor { inkLine(0.09) }
    public var trackHeaderLine: DrawColor { inkLine(0.12) }
    public var rulerLine: DrawColor { inkLine(0.28) }
    public var rulerMinor: DrawColor { inkLine(0.16) }
    public var playhead: DrawColor { palette.isDark ? DrawColor.white.alpha(0.92) : DrawColor(hex: 0x19191C, alpha: 0.92) }
    public var monitorBackdrop: DrawColor { DrawColor(hex: 0x2C2C2C) }
    /// `Theme.Colors.viewer`: the picture well behind a preview (the Export sheet's preview box).
    public var viewer: DrawColor { DrawColor(hex: 0x0C0C0C) }
    /// Monitor overlays (`Theme.Colors.guide` / `viewerHUD` / `platformMock`; `field` is in Inspector/InspectorControls).
    public var guide: DrawColor { DrawColor.white.alpha(0.55) }
    public var viewerHUD: DrawColor { DrawColor.black.alpha(0.55) }
    public var platformMock: DrawColor { DrawColor.white.alpha(0.62) }
    /// Handles and outlines drawn over the picture (`Theme.OnPicture.stroke` / `shadow` / `guideSnap`).
    public var onPictureStroke: DrawColor { .white }
    public var onPictureShadow: DrawColor { DrawColor.black.alpha(0.5) }
    public var guideSnap: DrawColor { DrawColor(hex: 0xFF4099) }
    /// Selected clips, snap line (DESIGN.md color roles).
    public var yellow: DrawColor { DrawColor(hex: 0xFFD60A) }
    public var onClip: DrawColor { .white }

    /// A clip's body color for its label (`LabelColor.rgb`) and its edge (`Theme.lift`, 11 % toward white).
    public func clip(_ label: LabelColor) -> DrawColor { DrawColor(hex: label.rgb) }
    public func clipEdge(_ label: LabelColor) -> DrawColor { clip(label).lifted(0.11) }

    /// `Theme.Metrics` / `Theme.Spacing` / `Theme.Radius` in points.
    public enum Metrics {
        public static let topBar: Float = 44
        public static let statusBar: Float = 28
        public static let panelHeader: Float = 30
        public static let trackV1: Float = 40
        public static let trackA1: Float = 32
        public static let trackOther: Float = 20
        public static let trackHeader: Float = 156
        public static let capsule: Float = 22
        public static let monitorHeader: Float = 32
        public static let monitorFooter: Float = 66
        /// Listening volume strip under the audio meter: slider and Dim button.
        public static let monitorStrip: Float = 44
        public static let monitorSliderMaxWidth: Float = 80
        public static let monitorSliderHeight: Float = 14
        public static let monitorDimWidth: Float = 22
        public static let monitorDimHeight: Float = 18
        public static let scrubBar: Float = 16
        public static let sequenceTabs: Float = 24
        /// Time ruler over the tracks.
        public static let ruler: Float = 24
        /// The clip name band at the top of a clip (DESIGN.md: 13 pt).
        public static let clipNameBand: Float = 13
        /// Gap between docked panel cards and around the workspace (`Theme.Spacing.paneDivider`).
        public static let paneDivider: Float = 2
    }
    public enum Spacing {
        public static let xxs: Float = 2, xs: Float = 4, sm: Float = 8, md: Float = 12, lg: Float = 16, xl: Float = 24
    }
    public enum Radius {
        public static let panel: Float = 3, small: Float = 4, control: Float = 6
    }
    /// Type sizes in points (`Theme.Typography`: caption 10, body 11, clip name 10.5, title 13, display 18).
    public enum TypeSize {
        public static let caption: Float = 10, body: Float = 11, clipName: Float = 10.5, title: Float = 13, display: Float = 18
    }
}

extension DrawTheme {
    /// `Theme.Palette.marker`: one marker color per `MarkerColor` (ruler, markers list, marker Color popup dots).
    public static func marker(_ c: MarkerColor) -> DrawColor {
        switch c {
        case .green: DrawColor(hex: 0x30D158)
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
