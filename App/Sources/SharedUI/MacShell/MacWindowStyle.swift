import AppKit
import SQDrawKit
import SQUIKit

/// What the Mac windows around the shared draw UI need from the design tokens: the system appearance, the window
/// backgrounds and the rounded hairline of a floating layer. All of it reads `DrawTheme` in the saved Appearance
/// (`sq.appearance.*`), the same theme the draw UI paints with; nothing here reads the AppKit `Theme`.
@MainActor
enum MacWindowStyle {
    /// The theme in the saved Appearance (mode, Background, Contrast).
    static var theme: DrawTheme { DrawTheme(settings: AppearanceSettings(defaults: .standard)) }

    /// System appearance that matches the mode (text cursor, scrollers, system sheets).
    static var appearance: NSAppearance? { NSAppearance(named: theme.palette.isDark ? .darkAqua : .aqua) }

    static func color(_ c: DrawColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }
    static var titlebar: NSColor { color(theme.titlebar) }
    static var canvas: NSColor { color(theme.canvas) }

    /// Opaque fill, hairline edge and the menu radius on a floating window's root layer (design B `--r-menu`).
    static func styleOverlay(_ layer: CALayer?) {
        let t = theme
        let edge = t.palette.ink.withAlpha(0.14)
        layer?.backgroundColor = color(t.overlay).cgColor
        layer?.cornerRadius = menuRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = CGFloat(SQTokens.Alpha.overlayEdgeWidth)
        layer?.borderColor = NSColor(srgbRed: edge.r / 255, green: edge.g / 255, blue: edge.b / 255, alpha: edge.a).cgColor
        layer?.masksToBounds = true
    }
    static let menuRadius: CGFloat = 10

    // The start window (about Finder's size) and the room its top bar gives the system lights.
    static let startWindowSize = NSSize(width: 1100, height: 720)
    static let startWindowMinSize = NSSize(width: 820, height: 520)
    static let startTopBar: CGFloat = 44
    static let startLightsFirstCenterX: CGFloat = 16 + 7
    static let startLightsPitch: CGFloat = 14 + 8 - 2
}
