import Foundation
import SQCore
import SQDrawKit
import SQUIKit

/// `Theme.Palette.marker` for panels outside the timeline (the Marker List's dots).
public enum TimelineMarkerColors {
    public static func color(_ c: MarkerColor, theme: DrawTheme = DrawTheme()) -> DrawColor { TimelineSkin(theme: theme).marker(c) }
}

/// The Mac `Theme` timeline tokens that `DrawTheme` does not carry yet, with the Mac values (ThemeTokens.swift,
/// `Theme.TimelineSkin`, `Theme.Selection`, `Theme.PlayheadSkin`). One place, so a token added to DrawTheme replaces a line here.
struct TimelineSkin {
    let theme: DrawTheme

    var accentTint: DrawColor { theme.accent.alpha(theme.palette.isDark ? 0.22 : 0.16) }
    var fill2: DrawColor { theme.inkFill(0.06) }
    var clipShade: DrawColor { DrawColor.black.alpha(0.22) }
    var snapLine: DrawColor { DrawColor(hex: 0xFFD60A) }
    var selectionOutline: DrawColor { .white }
    static let selectionOutlineWidth: CGFloat = 1.5
    var clipEdge: DrawColor { DrawColor.white.alpha(0.22) }
    /// `Theme.OnPicture.clipBadgeFill` / `clipBadgeEdge`: the rubber bands and their keys.
    var badgeFill: DrawColor { DrawColor.white.alpha(0.95) }
    var badgeEdge: DrawColor { DrawColor.black.alpha(0.6) }
    var thumbRule: DrawColor { DrawColor.black.alpha(0.35) }
    var thumbWell: DrawColor { DrawColor(hex: 0x2A2A2A) }
    var inOutBand: DrawColor { DrawColor.white.alpha(0.13) }
    var inOutBandEdge: DrawColor { DrawColor.white.alpha(0.38) }
    var cacheStrip: DrawColor { theme.accent.alpha(0.6) }
    var transitionIssue: DrawColor { red.alpha(0.55) }
    var hudFill: DrawColor { DrawColor.black.alpha(0.55) }
    var offlineClip: DrawColor { DrawColor(hex: 0x5A1F1C) }
    var offlineText: DrawColor { DrawColor(hex: 0xFF8A80) }
    var green: DrawColor { DrawColor(hex: 0x30D158) }
    var warning: DrawColor { Self.color(theme.palette.warning) }
    var red: DrawColor { Self.color(theme.palette.red) }
    var headTop: DrawColor { DrawColor(hex: 0xFFFFFF) }
    var headBottom: DrawColor { DrawColor(hex: 0xC3C9D9) }
    var headOutline: DrawColor { theme.palette.isDark ? .clear : DrawColor(hex: 0x19191C, alpha: 0.75) }

    static func color(_ c: PaletteColor) -> DrawColor {
        DrawColor(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, Float(c.a))
    }

    /// `Theme.Palette.marker`.
    func marker(_ c: MarkerColor) -> DrawColor { DrawTheme.marker(c) }

    /// Clip name color on a label fill: white unless white falls under WCAG 4.5:1 on it (`LabelColor+ClipFill`).
    static func text(on fill: DrawColor) -> DrawColor {
        func lin(_ v: Float) -> Float { v <= 0.03928 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * lin(fill.r) + 0.7152 * lin(fill.g) + 0.0722 * lin(fill.b)
        return 1.05 / (lum + 0.05) < 4.5 ? .black : .white
    }

    // MARK: Playhead head (`Theme.PlayheadSkin`, pip-head.svg in its 780 x 776 box, flattened once)

    static let headSize = CGSize(width: 12, height: 12)
    /// The head outline in head-local points (0...12), bezier corners flattened to 6 steps each.
    static let headOutlinePoints: [CGPoint] = {
        var out: [CGPoint] = []
        var cur = CGPoint(x: 250.96, y: 152.12)
        func line(_ p: CGPoint) { out.append(p); cur = p }
        func curve(_ p: CGPoint, _ c1: CGPoint, _ c2: CGPoint) {
            let a = cur
            for i in 1...6 {
                let t = CGFloat(i) / 6, u = 1 - t
                let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x
                let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y
                out.append(CGPoint(x: x, y: y))
            }
            cur = p
        }
        out.append(cur)
        line(CGPoint(x: 773.04, y: 152.12))
        curve(CGPoint(x: 902, y: 281.08), CGPoint(x: 855.62, y: 152.12), CGPoint(x: 902, y: 198.5))
        line(CGPoint(x: 902, y: 620.12))
        curve(CGPoint(x: 824, y: 738.68), CGPoint(x: 902, y: 669.94), CGPoint(x: 865.18, y: 707.58))
        line(CGPoint(x: 609.55, y: 900.92))
        curve(CGPoint(x: 414.45, y: 900.92), CGPoint(x: 561.4, y: 937.32), CGPoint(x: 462.6, y: 937.32))
        line(CGPoint(x: 200, y: 738.68))
        curve(CGPoint(x: 122, y: 620.12), CGPoint(x: 158.82, y: 707.58), CGPoint(x: 122, y: 669.94))
        line(CGPoint(x: 122, y: 281.08))
        curve(CGPoint(x: 250.96, y: 152.12), CGPoint(x: 122, y: 198.5), CGPoint(x: 168.38, y: 152.12))
        out.removeLast()                                    // closes on the first point
        return out.map { CGPoint(x: ($0.x - 122) * headSize.width / 780, y: ($0.y - 152) * headSize.height / 776) }
    }()

    /// `Theme.PlayheadSkin.drawHead`: the gradient head over the line at `c`, top at `top`.
    /// shortcut: the gradient is one polygon fill per 1 pt band; upgrade with a gradient quad kind in the canvas.
    func drawHead(_ cv: inout Canvas, centerX c: CGFloat, top: CGFloat = 0) {
        let pts = Self.headOutlinePoints.map { CGPoint(x: c - Self.headSize.width / 2 + $0.x, y: top + $0.y) }
        let bands = Int(Self.headSize.height)
        for i in 0..<bands {
            let t = Float(i) / Float(max(bands - 1, 1))
            let col = DrawColor(headTop.r + (headBottom.r - headTop.r) * t, headTop.g + (headBottom.g - headTop.g) * t,
                                headTop.b + (headBottom.b - headTop.b) * t, 1)
            cv.saveGState()
            cv.clip(to: CGRect(x: c - 8, y: top + CGFloat(i), width: 16, height: 1))
            cv.fill(polygon: pts, col)
            cv.restoreGState()
        }
        if headOutline.a > 0 { cv.stroke(polygon: pts, width: 1, headOutline) }
    }

    /// `Theme.PlayheadSkin.lineFrame`: the 2 pt line centered on `x`.
    static func lineFrame(centerX x: CGFloat, y: CGFloat = 0, height: CGFloat) -> CGRect {
        CGRect(x: x.rounded() - 1, y: y, width: 2, height: height)
    }
}
