import Foundation

/// Dark (default) or Light; Light is derived from the dark app palette (design B v7 theme engine).
public enum AppearanceMode: String, Sendable, CaseIterable, Equatable {
    case dark, light
}

/// The user's Appearance choice: mode, Background (-6 to +6) and Contrast (0 to 100, 50 = the app values).
/// Persisted as `sq.appearance.mode` / `.background` / `.contrast`.
public struct AppearanceSettings: Equatable, Sendable, CustomStringConvertible {
    public static let backgroundRange = -6...6
    public static let contrastRange = 0...100
    public static let standard = AppearanceSettings()
    public static let modeKey = "sq.appearance.mode"
    public static let backgroundKey = "sq.appearance.background"
    public static let contrastKey = "sq.appearance.contrast"

    public var mode: AppearanceMode
    public var background: Int { didSet { background = Self.clamp(background, Self.backgroundRange) } }
    public var contrast: Int { didSet { contrast = Self.clamp(contrast, Self.contrastRange) } }

    public init(mode: AppearanceMode = .dark, background: Int = 0, contrast: Int = 50) {
        self.mode = mode
        self.background = Self.clamp(background, Self.backgroundRange)
        self.contrast = Self.clamp(contrast, Self.contrastRange)
    }

    public init(defaults: UserDefaults) {
        let mode = defaults.string(forKey: Self.modeKey).flatMap(AppearanceMode.init(rawValue:)) ?? .dark
        let bg = defaults.object(forKey: Self.backgroundKey) as? Int ?? 0
        let ct = defaults.object(forKey: Self.contrastKey) as? Int ?? 50
        self.init(mode: mode, background: bg, contrast: ct)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(background, forKey: Self.backgroundKey)
        defaults.set(contrast, forKey: Self.contrastKey)
    }

    public var description: String { "\(mode.rawValue) bg \(background) ct \(contrast)" }

    private static func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(max(v, r.lowerBound), r.upperBound) }
}

/// An sRGB color, components 0...255, alpha 0...1. Pure, so the palette math is testable without AppKit.
public struct PaletteColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(r: Double((hex >> 16) & 0xFF), g: Double((hex >> 8) & 0xFF), b: Double(hex & 0xFF), a: alpha)
    }
    public static let white = PaletteColor(hex: 0xFFFFFF)
    public static let black = PaletteColor(hex: 0x000000)

    /// Rounded to whole 0...255 steps (the design's `toHex`).
    var quantized: PaletteColor {
        func q(_ v: Double) -> Double { min(max(v, 0), 255).rounded() }
        return PaletteColor(r: q(r), g: q(g), b: q(b), a: a)
    }
    func map(_ f: (Double) -> Double) -> PaletteColor { PaletteColor(r: f(r), g: f(g), b: f(b), a: a) }
    public func withAlpha(_ alpha: Double) -> PaletteColor { PaletteColor(r: r, g: g, b: b, a: alpha) }

    /// This color with `ink` laid over it at `alpha` (opaque result).
    public func over(_ ink: PaletteColor, _ alpha: Double) -> PaletteColor {
        PaletteColor(r: r + (ink.r - r) * alpha, g: g + (ink.g - g) * alpha, b: b + (ink.b - b) * alpha).quantized
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ v: Double) -> Double { let c = v / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    /// WCAG contrast ratio (1...21).
    public func contrast(with o: PaletteColor) -> Double {
        let x = luminance, y = o.luminance
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// The resolved surfaces and text of one `AppearanceSettings` (port of the design's `resolve(mode, background, contrast)`).
/// Translucent tokens (fills, lines) are built in `Theme` from `ink` and `lineScale`.
public struct AppearancePalette: Equatable, Sendable {
    public var mode: AppearanceMode
    public var canvas, divider, titlebar, panel, content, lane, timeline, overlay: PaletteColor
    public var label, label2, label3: PaletteColor
    /// White in dark mode, black in light: the ink of every translucent fill and line.
    public var ink: PaletteColor
    /// Multiplier of hairline alphas (Contrast slider).
    public var lineScale: Double
    public var accent, accentFill, warning, red, keyframe: PaletteColor

    public var isDark: Bool { mode == .dark }
    /// Fill alpha in this mode for a dark-mode alpha (light uses black ink, a little softer).
    public func fillAlpha(_ dark: Double) -> Double { isDark ? dark : dark * 0.65 }
    /// Hairline alpha for a dark-mode alpha, scaled by Contrast.
    public func lineAlpha(_ dark: Double) -> Double { dark * lineScale * (isDark ? 1 : 0.8) }

    /// Opaque selection and field over the panel (the text contrast checks run on these).
    public var selectionOnPanel: PaletteColor { panel.over(ink, isDark ? 0.14 : 0.08) }
    public var fieldOnPanel: PaletteColor { panel.over(.black, isDark ? 0.28 : 0.05) }

    /// The lowest text contrast over the resting surfaces (shown in the Appearance popover; never under 4.5).
    public var lowestTextContrast: Double {
        let surfaces = [panel, titlebar, overlay, content, timeline, fieldOnPanel]
        var m = Double.infinity
        for t in [label, label2, label3] { for s in surfaces { m = min(m, t.contrast(with: s)) } }
        for t in [label, label2] { m = min(m, t.contrast(with: selectionOnPanel)) }
        return m
    }

    private static let darkSurfaces: [UInt32] = [0x141416, 0x080809, 0x232326, 0x1E1E21, 0x19191C, 0x18181B, 0x151518, 0x2A2A2E]
    private static let lightSurfaces: [UInt32] = [0xDCDCDF, 0xD0D0D4, 0xEEEEF0, 0xFFFFFF, 0xF7F7F8, 0xF4F4F5, 0xF1F1F3, 0xEBEBED]
    private static let darkText: [UInt32] = [0xE6E6E8, 0xB2B2B8, 0x9C9CA2]
    private static let lightText: [UInt32] = [0x19191C, 0x4C4C52, 0x5E5E64]

    public static func resolve(_ s: AppearanceSettings) -> AppearancePalette {
        let d = s.mode == .dark
        let ct = Double(s.contrast), bg = Double(s.background)
        let k = ct <= 50 ? 0.4 + ct * 0.012 : 1 + (ct - 50) * 0.016
        let f = d ? 2.2 : 1.6
        let anchor = d ? PaletteColor(hex: 0x141416) : .white
        let src = (d ? darkSurfaces : lightSurfaces).map { PaletteColor(hex: $0) }
        // Canvas and divider (dark) only follow Background; every other surface spreads away from the anchor with Contrast.
        let surf: [PaletteColor] = src.enumerated().map { i, c in
            if d && i < 2 { return c.map { $0 + bg * f }.quantized }
            return PaletteColor(r: anchor.r + (c.r - anchor.r) * k + bg * f,
                                g: anchor.g + (c.g - anchor.g) * k + bg * f,
                                b: anchor.b + (c.b - anchor.b) * k + bg * f).quantized
        }
        var p = AppearancePalette(
            mode: s.mode, canvas: surf[0], divider: surf[1], titlebar: surf[2], panel: surf[3], content: surf[4],
            lane: surf[5], timeline: surf[6], overlay: surf[7],
            label: .white, label2: .white, label3: .white,
            ink: d ? .white : .black,
            lineScale: ct <= 50 ? 0.5 + ct * 0.01 : 1 + (ct - 50) * 0.016,
            accent: PaletteColor(hex: d ? 0xA56BFF : 0x7A33E0), accentFill: PaletteColor(hex: 0x7C3AED),   // P3 Violett (DECISIONS 2026-10-13)
            warning: PaletteColor(hex: d ? 0xFF9F0A : 0xA35C00), red: PaletteColor(hex: d ? 0xFF453A : 0xC4281E),
            keyframe: PaletteColor(hex: d ? 0xD6D6D6 : 0x4C4C52))
        // Text: app values at contrast 50, shifted with the sliders, then raised until every resting surface reads at 4.5:1.
        let surfaces = [p.panel, p.titlebar, p.overlay, p.content, p.timeline, p.fieldOnPanel]
        let text = (d ? darkText : lightText).map { PaletteColor(hex: $0) }
        var out: [PaletteColor] = []
        for (i, t) in text.enumerated() {
            let shift = (ct - 50) * (i == 0 ? 0.2 : 0.6) + bg * f * 0.6
            var c = t.map { $0 + (d ? shift : -shift) }.quantized
            let checks = i < 2 ? surfaces + [p.selectionOnPanel] : surfaces
            var guardSteps = 0
            while guardSteps < 255, !checks.allSatisfy({ c.contrast(with: $0) >= 4.5 }) {
                c = c.map { $0 + (d ? 1 : -1) }.quantized
                guardSteps += 1
            }
            out.append(c)
        }
        p.label = out[0]; p.label2 = out[1]; p.label3 = out[2]
        if !d { p.keyframe = p.label2 }
        return p
    }
}
