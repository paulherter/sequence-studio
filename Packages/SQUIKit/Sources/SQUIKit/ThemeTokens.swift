import AppKit
import SwiftUI
import SQCore
import SQText

/// The ONE token set of docs/DESIGN-SYSTEM.md part 1 (names listed in its "Token API" section).
/// New code uses these; the older `Theme.Fonts` / `Theme.Metrics` names stay until each area is migrated.
extension Theme {
    /// Type scale (DESIGN-SYSTEM 1.2): SF Pro with monospaced digits, sizes 10 / 11 / 13 / 18, weights Regular and Medium only.
    /// (`Theme.Type` would be the metatype, hence `Typography`.) NSFont for AppKit drawing, `…Font` for SwiftUI.
    public enum Typography {
        public static var captionSize: CGFloat { UIScale.scaled(10) }
        public static var bodySize: CGFloat { UIScale.scaled(11) }
        public static var titleSize: CGFloat { UIScale.scaled(13) }
        public static var displaySize: CGFloat { UIScale.scaled(18) }
        public static var sizes: [CGFloat] { [captionSize, bodySize, titleSize, displaySize] }
        /// Board clip "fx" pill: 9 pt bold (outside the four UI sizes on purpose, it is a badge).
        public static var badge: NSFont { NSFont.systemFont(ofSize: UIScale.scaled(9), weight: .bold) }

        nonisolated(unsafe) private static var fontCache: [String: NSFont] = [:]
        private static let fontLock = NSLock()
        /// Cached per size and weight: the tokens are computed now, so a font is built once, not on every read.
        public static func ns(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let key = "\(size)/\(weight.rawValue)"
            fontLock.lock(); defer { fontLock.unlock() }
            if let f = fontCache[key] { return f }
            let f = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            fontCache[key] = f
            return f
        }
        static func ui(_ size: CGFloat, _ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: size, weight: weight).monospacedDigit()
        }

        /// 10 regular: ruler, column headers, status bar, meter scale, timeline clip names, badges, HUD.
        public static var caption: NSFont { ns(captionSize, .regular) }
        /// 9.5 regular: timeline clip names (board `.clip`, outside the four UI sizes on purpose).
        public static var clipName: NSFont { ns(UIScale.scaled(10.5), .medium) }       // design v9 `.clip .cl`
        /// 10 medium: menu section headers, Effect Controls group titles, clip badges, key caps.
        public static var captionStrong: NSFont { ns(captionSize, .medium) }
        /// 11 regular: default UI text (rows, controls, fields, tabs, labels).
        public static var body: NSFont { ns(bodySize, .regular) }
        /// Body with tabular (fixed-width) digits, for columns of numbers.
        public static var tabularBody: NSFont { NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular) }
        /// 11 medium: names, selected tab, panel section titles, segmented.
        public static var bodyStrong: NSFont { ns(bodySize, .medium) }
        /// 13 regular: menus (rows + shortcuts), dialog body.
        public static var title: NSFont { ns(titleSize, .regular) }
        /// 13 medium: dialog / sheet / export title.
        public static var titleStrong: NSFont { ns(titleSize, .medium) }
        /// 18 regular: viewer timecode, Quick Apply search field (no medium).
        public static var display: NSFont { ns(displaySize, .regular) }
        /// v9 `--fs-lab`, 12 regular: rows and fields of the right column lists (Library, Effects, Project, Keystones).
        public static var listSize: CGFloat { UIScale.scaled(12) }
        public static var list: NSFont { ns(listSize, .regular) }
        /// v9 list column headers and group captions: 11 semibold, drawn in `label3`.
        public static var listHeader: NSFont { ns(bodySize, .semibold) }
        /// 12 regular with tabular digits: number columns of the panel lists (Duration).
        public static var tabularList: NSFont { NSFont.monospacedDigitSystemFont(ofSize: listSize, weight: .regular) }
        /// 15 semibold (v9 `--fs-h`): the one heading of every empty state (merged from emptyTitle, 13).
        public static var emptyHeading: NSFont { ns(UIScale.scaled(15), .semibold) }
        public static var listFont: SwiftUI.Font { ui(listSize, .regular) }
        public static var emptyHeadingFont: SwiftUI.Font { ui(UIScale.scaled(15), .semibold) }
        /// 12 regular (v9 `--fs-lab`): top bar controls, monitor duration.
        public static var shell: NSFont { ns(UIScale.scaled(12), .regular) }
        /// 12 semibold: the monitor timecode (v9 `.tcd`).
        public static var shellStrong: NSFont { ns(UIScale.scaled(12), .semibold) }
        /// 13 semibold: the project name in the top bar (v9 `.top .title`).
        public static var windowTitle: NSFont { ns(titleSize, .semibold) }

        public static var captionFont: SwiftUI.Font { ui(captionSize, .regular) }
        public static var captionStrongFont: SwiftUI.Font { ui(captionSize, .medium) }
        public static var bodyFont: SwiftUI.Font { ui(bodySize, .regular) }
        public static var bodyStrongFont: SwiftUI.Font { ui(bodySize, .medium) }
        public static var titleFont: SwiftUI.Font { ui(titleSize, .regular) }
        public static var titleStrongFont: SwiftUI.Font { ui(titleSize, .medium) }
        public static var displayFont: SwiftUI.Font { ui(displaySize, .regular) }

        /// Icon sizes (one stroke, the SQIcon renderer): in 10 pt rows/chips, inline with body, chrome/tool buttons.
        public static let symbolSmall: CGFloat = 9
        public static let symbolInline: CGFloat = 11
        public static let symbolChrome: CGFloat = 13
    }

    /// Dialog card and its buttons (design B `.sheet`, `.alert`): the card is rounder than other floating layers, buttons sit 28 high.
    public enum Dialog {
        public static let cardRadius: CGFloat = 14
        public static let buttonHeight: CGFloat = 28
        /// Import report list well (board `.well` inside the report card).
        public static let reportWellRadius: CGFloat = 6
        /// Text on the overlay fill: the opaque label colors (translucent text draws too bright in AppKit text fields).
        public static let titleColor = Theme.Colors.label
        public static let noteColor = Theme.Colors.label2
        public static let hintColor = Theme.Colors.label3
    }

    /// Row and bar heights per family (DESIGN-SYSTEM 1.4).
    public enum Row {
        /// List, menu, property and section-header rows.
        public static var standard: CGFloat { UIScale.scaled(24) }
        public static let list: CGFloat = standard
        /// v9 editor `--h-row`: rows and column headers of the right column lists (Library, Effects, Project, Keystones).
        public static var panelList: CGFloat { UIScale.scaled(26) }
        public static let menu: CGFloat = Theme.Menu.rowHeight
        public static let property: CGFloat = standard
        public static let sectionHeader: CGFloat = standard
        /// Media row with a thumbnail (Library media list only).
        public static var thumb: CGFloat { UIScale.scaled(28) }
        /// Panel header / tab strip (`PanelID.headerHeight` must equal it).
        public static var panelHeader: CGFloat { UIScale.scaled(30) }
        public static var columnHeader: CGFloat { UIScale.scaled(22) }
        public static var topBar: CGFloat { UIScale.scaled(44) }
        public static var statusBar: CGFloat { UIScale.scaled(28) }
        public static var timelineHeader: CGFloat { UIScale.scaled(30) }
        /// Control in panels (button, popup, field, scrub field, segmented).
        public static var control: CGFloat { UIScale.scaled(22) }
        /// Control in floating layers and the top bar.
        public static var controlLarge: CGFloat { UIScale.scaled(24) }
        public static var swatch: CGSize { CGSize(width: UIScale.scaled(38), height: UIScale.scaled(20)) }
    }

    /// Interaction states, one token per state everywhere (DESIGN-SYSTEM 1.6 table).
    public enum State {
        /// Control box at rest / hover / pressed.
        public static let controlRest = Colors.fill
        public static let controlHover = Colors.fillHover
        public static let pressed = Colors.fillPressed
        /// Row, tile and menu item hover (was `Colors.overlayHover`).
        public static let rowHover = Colors.overlayHover
        /// The caption plate behind the word boxes on the caption track (alpha of `clipCaption`).
        public static let captionPlateAlpha: CGFloat = 0.32
        /// Selected row / tile / grid item.
        public static let selected = Colors.selection
        /// Selected segment inside a segmented control.
        public static let selectedSegment = Colors.fillPressed
        /// Selected while its panel has focus (targeted track, focused grid).
        public static let selectedFocused = Colors.accentTint
        /// 1 px focus ring on fields, scrub fields, search.
        public static let focusRing = Colors.accentRing
        /// 1 px outline of the focused panel.
        public static let panelFocusRing = Colors.focusRing
        public static let focusRingWidth: CGFloat = 1
        /// Keyboard focus on a control (sq.css `.foc`): inner 1.5 px accent line.
        public static let focusLine = Colors.accent
        public static let focusLineWidth: CGFloat = 1.5
        /// Drop target: 1 px `focusRing` edge plus this fill.
        public static let dropTargetFill = Theme.dynamic { $0.accent.withAlpha(0.10) }
        /// Disabled: text uses `disabledText`, glyphs and fills are drawn at `disabledAlpha`.
        public static let disabledText = Colors.label3
        public static let disabledAlpha: CGFloat = 0.4
        /// Primary action: fill `accent`, pressed `accentFill`, text `onAccent`.
        public static let primary = Colors.accent
        public static let primaryPressed = Colors.accentFill
        public static let onAccent = Theme.white(1)
    }

    /// Hairlines and pane splits.
    public enum Separator {
        /// 1 px hairline between rows / sections.
        public static let hairline = Colors.separator
        /// Pane splits only.
        public static let divider = Colors.divider
        public static let width: CGFloat = 1
    }

    /// Colors drawn on top of the picture or on clips (DESIGN-SYSTEM 1.6 "new tokens").
    public enum OnPicture {
        /// Transform, crop and text-edit overlay strokes / handles.
        public static let stroke = Theme.white(1)
        public static let shadow = Theme.black(0.5)
        /// Magic mask click points on the picture: add (+) and remove (-) dots.
        public static let magicAdd = Colors.green
        public static let magicRemove = Colors.red
        /// Smart-guide snap line.
        public static let guideSnap = Theme.hex(0xFF4099)
        /// Backdrop of text on the picture (scrub HUD).
        public static let hudFill = Colors.viewerHUD
        /// Safe-margin guides.
        public static let guide = Colors.guide
        /// FX / speed / keystone badges on clips.
        public static let clipBadgeFill = Theme.white(0.95)
        public static let clipBadgeEdge = Theme.black(0.6)
        /// Drag ghost of a clip: its own color at this alpha.
        public static let clipGhostAlpha: CGFloat = 0.55
        public static let offlineClip = Theme.hex(0x5A1F1C)
    }

    /// Category palettes as Theme data instead of view literals.
    public enum Palette {
        /// Marker colors (ruler, markers list).
        public static func marker(_ c: MarkerColor) -> NSColor {
            switch c {
            case .green: Colors.green
            case .red: NSColor(srgbRed: 0.93, green: 0.30, blue: 0.28, alpha: 1)
            case .purple: NSColor(srgbRed: 0.62, green: 0.42, blue: 0.90, alpha: 1)
            case .orange: NSColor(srgbRed: 0.96, green: 0.58, blue: 0.20, alpha: 1)
            case .yellow: NSColor(srgbRed: 0.95, green: 0.82, blue: 0.25, alpha: 1)
            case .white: NSColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1)
            case .blue: NSColor(srgbRed: 0.30, green: 0.52, blue: 0.95, alpha: 1)
            case .cyan: NSColor(srgbRed: 0.28, green: 0.82, blue: 0.88, alpha: 1)
            }
        }

        /// Keyboard shortcut groups (keyboard layout view).
        public static func shortcutGroup(_ g: KeyGroup) -> NSColor {
            switch g {
            case .transport: NSColor(srgbRed: 0.30, green: 0.62, blue: 0.95, alpha: 1)
            case .marking: NSColor(srgbRed: 0.95, green: 0.72, blue: 0.25, alpha: 1)
            case .tools: NSColor(srgbRed: 0.62, green: 0.45, blue: 0.92, alpha: 1)
            case .editing: NSColor(srgbRed: 0.93, green: 0.40, blue: 0.40, alpha: 1)
            case .clipboard: NSColor(srgbRed: 0.35, green: 0.78, blue: 0.55, alpha: 1)
            case .view: NSColor(srgbRed: 0.30, green: 0.78, blue: 0.82, alpha: 1)
            case .file: NSColor(srgbRed: 0.65, green: 0.65, blue: 0.70, alpha: 1)
            case .audio: NSColor(srgbRed: 0.90, green: 0.55, blue: 0.80, alpha: 1)
            case .keyframes: NSColor(srgbRed: 0.80, green: 0.85, blue: 0.35, alpha: 1)
            case .other: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)
            }
        }

        /// One color per animated property in the graph editor (Position, Scale, Rotation, Opacity, Anchor, Volume, Shutter, …).
        public static let graphCurve: [NSColor] = [
            Theme.hex(0xFF8FC0), Theme.hex(0xFF5A4E), Theme.hex(0x3FD0E0), Theme.hex(0x5FE3B8),
            Theme.hex(0xC58AF9), Theme.hex(0x5FD068), Theme.hex(0xFF9F0A),
            Theme.hex(0xFFD60A), Theme.hex(0x64B5FF), Theme.hex(0x9FD98A), Theme.hex(0xE0C080), Theme.hex(0xB0B0B0),
        ]
    }
}

extension Theme.Palette {
    /// Transparency checkerboard (color wells, alpha slider).
    public static let checker = (dark: NSColor(white: 0.30, alpha: 1), light: NSColor(white: 0.45, alpha: 1))
}

// MARK: - WP-A: motion, selection, inspector geometry (docs/DESIGN-SYSTEM.md "Token API")

extension Theme {
    /// Animation tokens (DESIGN-SYSTEM "Motion"). Every animation in the app uses one of these durations and curves.
    public enum Motion {
        /// Small state changes: hover, zoom steps, popover/menu fade.
        public static let fast: Double = 0.12
        /// Panels, sheets, larger layout changes.
        public static let standard: Double = 0.2
        /// Rare, large movements (workspace switch).
        public static let slow: Double = 0.3

        /// Pure easing curves (progress 0...1 in, 0...1 out, endpoints exact, monotonic).
        public enum Curve: Sendable, Equatable {
            case linear, easeOut, easeInOut

            public func value(_ t: Double) -> Double {
                let c = min(max(t, 0), 1)
                switch self {
                case .linear: return c
                case .easeOut: return 1 - pow(1 - c, 3)                                  // cubic: fast start, soft landing
                case .easeInOut: return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
                }
            }

            /// The same curve for Core Animation / NSAnimationContext.
            public var timingFunction: CAMediaTimingFunction {
                switch self {
                case .linear: CAMediaTimingFunction(name: .linear)
                case .easeOut: CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)    // cubic ease-out
                case .easeInOut: CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)  // cubic ease-in-out
                }
            }
        }

        /// SwiftUI spring for direct-manipulation settles (snappy, no visible bounce).
        public static let spring = SwiftUI.Animation.spring(response: standard + 0.08, dampingFraction: 0.9)
        /// SwiftUI twin of `Curve.easeOut` over `fast`.
        public static let easeOutAnimation = SwiftUI.Animation.timingCurve(0.33, 1, 0.68, 1, duration: fast)

        /// `seconds`, or 0 when the user asked for reduced motion.
        @MainActor public static func duration(_ seconds: Double) -> Double {
            duration(seconds, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        /// Pure form of `duration(_:)`.
        public static func duration(_ seconds: Double, reduceMotion: Bool) -> Double { reduceMotion ? 0 : seconds }

        /// The one show animation for popovers, menus and sheets: fade in over `fast`, ease-out.
        @MainActor public static func fadeIn(_ window: NSWindow) {
            let d = duration(fast)
            guard d > 0 else { window.alphaValue = 1; return }
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = d
                ctx.timingFunction = Curve.easeOut.timingFunction
                window.animator().alphaValue = 1
            }
        }
        /// The matching hide animation; `completion` runs after the fade (close / orderOut there).
        @MainActor public static func fadeOut(_ window: NSWindow, completion: @escaping @MainActor () -> Void) {
            let d = duration(fast)
            guard d > 0 else { completion(); return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = d
                ctx.timingFunction = Curve.easeOut.timingFunction
                window.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { completion(); window.alphaValue = 1 }
            })
        }
    }

    /// One selection style app-wide (DECISIONS 2026-10-03 "Interaction rules"): neutral fill, accent only for focus/active.
    public enum Selection {
        /// Selected row / tile / layer / inspector row while its panel is not focused.
        public static let fill = State.selected
        /// Selected while its panel (table) has keyboard focus: a brighter neutral, still no accent.
        public static let fillFocused = Theme.dynamic { $0.ink.withAlpha($0.isDark ? 0.15 : 0.10) }
        /// Hover over an unselected row / tile.
        public static let hover = State.rowHover
        /// Timeline objects (clips, transitions, gaps): outline instead of a fill.
        public static let outline = Colors.clipSelect
        public static let outlineWidth: CGFloat = 1.5
        public static let text = Colors.label
        public static let secondaryText = Colors.label2

        /// Fills `rect` with the selection color for the focus state.
        @MainActor public static func draw(in rect: NSRect, focused: Bool) {
            (focused ? fillFocused : fill).setFill()
            rect.fill()
        }
    }

    /// The one column grid of the Controls column and every inspector row (`ControlsGrid` reads these; nothing else
    /// may place a row part by a number of its own). Left to right: inset, toggle column (chevron, animate diamond,
    /// checkbox), gap, label column, gap, value columns, gap, tail column (reset or key navigation), trailing inset.
    /// Every edge is the outer bound of the control in that column, never the text inside it.
    public enum Inspector {
        /// Left inset = left edge of the toggle column.
        public static let ringX: CGFloat = Spacing.sm
        /// Toggle column: chevron, animate diamond / ring and a row's checkbox share it (all centered in it).
        public static let toggleWidth: CGFloat = Metrics.checkbox
        /// The one gap between the bounds of neighboring columns and of neighboring controls in a row.
        public static let columnGap: CGFloat = Spacing.iconToLabel
        public static let nameX: CGFloat = ringX + toggleWidth + columnGap
        public static let nameWidth: CGFloat = 88
        public static let controlX: CGFloat = nameX + nameWidth + columnGap
        /// One step in: the rows of an opened section start this far right of the section's chevron and title, like
        /// the items of an opened folder in the list panels (the same step as a nested Library section).
        public static let rowIndent: CGFloat = Spacing.md
        /// One number field; the n-th field of a row starts at `controlX + n * (valueWidth + columnGap)`.
        public static let valueWidth: CGFloat = 50
        /// The control column: the widest any control of a row grows from the first value column (three value columns and
        /// their two gaps). Popups, segmented controls, fonts and slider tracks fill it, never more, whatever the panel width.
        public static let controlColumnWidth: CGFloat = 3 * valueWidth + 2 * columnGap
        /// Tail column, ending at the trailing inset: a reset arrow, or the key navigation of a keyframable row.
        public static let resetWidth: CGFloat = Row.control
        public static let navigationWidth: CGFloat = 72
        public static let labelHeight: CGFloat = 14
        public static let iconSlot: CGFloat = 18
        public static let trailing: CGFloat = Spacing.md
        /// Row pitch (design v9 `--h-row`): one height for section rows and parameter rows.
        public static let rowHeight: CGFloat = 26
        public static let headerHeight: CGFloat = rowHeight
        /// Space between the last row of an open section and the next section header.
        public static let sectionGap: CGFloat = Spacing.xs
        /// A timecode field (wider than a number field: eleven tabular digits and separators).
        public static let timecodeWidth: CGFloat = 78
        /// Widest a parameter row of a panel body grows (sliders, wheels block): label 96 + slider + value stays readable;
        /// a wider panel keeps the rows leading-aligned at this width, like the Edit page's Controls.
        public static let maxRowWidth: CGFloat = 480
        /// Widest a choice popup grows in a parameter row.
        public static let popupWidth: CGFloat = 120
        /// The narrow choice popup beside a wide one (Shape / Brightness of a Picture mask).
        public static let channelWidth: CGFloat = 84
        /// Opened keyframe row: the speed curve of one property.
        public static let graphHeight: CGFloat = 120
        /// The crossover strip of the multiband compressor in the Audio section.
        public static let bandsHeight: CGFloat = 84
    }
}

/// Color page palettes (moved here from ColorControls so every literal color lives in the theme files).
extension Theme.Palette {
    /// White-balance sliders: temperature (blue to orange) and tint (green to magenta) tracks, neutral in the middle.
    public static let whiteBalanceTemperature: [NSColor] = [Theme.hex(0x4F8FF0), Theme.white(0.54), Theme.hex(0xF0A53C)]
    public static let whiteBalanceTint: [NSColor] = [Theme.hex(0x3FC36A), Theme.white(0.54), Theme.hex(0xD463D8)]
    /// Saturation and Vibrance slider track (version 9 `.ramp.sat`): gray into color.
    public static let saturationRamp: [NSColor] = [Theme.white(0.54), Theme.hex(0x9A86B5), Theme.hex(0xC98199), Theme.hex(0xD9A25B)]
    /// Slider knob (design source #f2f2f2) and its shadow.
    public static let sliderKnob: NSColor = Theme.Colors.sliderKnob
    public static let sliderKnobShadow: NSColor = Theme.black(0.6)
    /// Channel selector dots of the curve editor: master, red, green, blue.
    public static let channelDots: [NSColor] = [Theme.white(0.9), Theme.Colors.red, Theme.Colors.green, channelBlue]
    /// The blue color channel (a data color, not the app accent).
    public static let channelBlue: NSColor = Theme.hex(0x4D8CFF)
}

// MARK: - Color conversion and text-box defaults (lint-ui: literal colors live in the token files only)

extension Theme {
    /// Conversions between stored model colors (sRGB components) and NSColor, and the few computed palettes.
    public enum ColorBridge {
        /// An sRGB color from components.
        public static func srgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
        /// A color from hue (0...1), saturation, brightness: hue rings and hue strips.
        public static func hsb(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
        }
        public static func ns(_ c: RGBAColor) -> NSColor { srgb(c.red, c.green, c.blue, c.alpha) }
        public static func ns(_ c: EffectColor) -> NSColor { srgb(c.red, c.green, c.blue, c.alpha) }
        /// The color converted to sRGB (falls back to the color itself), optionally with another opacity.
        public static func rgba(_ c: NSColor, alpha: Double? = nil) -> RGBAColor {
            let s = c.usingColorSpace(.sRGB) ?? c
            return RGBAColor(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent, alpha: alpha ?? s.alphaComponent)
        }
        /// The color as an effect color; nil when it has no sRGB representation.
        public static func effectColor(_ c: NSColor, alpha: Double? = nil) -> EffectColor? {
            c.usingColorSpace(.sRGB).map {
                EffectColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: alpha ?? $0.alphaComponent)
            }
        }
        /// The same color at another opacity.
        public static func withAlpha(_ c: RGBAColor, _ alpha: Double) -> RGBAColor {
            RGBAColor(red: c.red, green: c.green, blue: c.blue, alpha: alpha)
        }
    }

    /// Defaults the text inspector restores when a box background or shadow is switched on again.
    public enum TextDefaults {
        public static let backgroundColor = ColorBridge.withAlpha(.black, 0.75)
        public static let backgroundPadding = BoxPadding(horizontal: 16, vertical: 8)
        public static let backgroundRadius: Double = 8
        public static let shadowColor = ColorBridge.withAlpha(.black, 0.6)
        public static let karaokeHighlight = ColorBridge.srgb(1, 0.86, 0.1)
    }
}

// MARK: - Playhead K1 and icon gradient colors (literals live in the token files only)

extension Theme.PlayheadSkin {
        /// Porcelain gradient, top and bottom (icon head: #FFFFFF to #C3C9D9).
        public static let headTop = Theme.hex(0xFFFFFF)
        public static let headBottom = Theme.hex(0xC3C9D9)
        /// Dark hairline around the head in the light appearance only (the porcelain needs it on a light timeline).
        public static let headOutline = Theme.dynamic { $0.isDark ? PaletteColor.black.withAlpha(0) : PaletteColor(hex: 0x19191C, alpha: 0.75) }
}

extension Theme {
    /// App icon gradient (dark violet through magenta to orange): export progress and the finished state only.
    public enum IconGradient {
        public static let stops: [NSColor] = [Theme.hex(0x350670), Theme.hex(0x8727C7), Theme.hex(0xEF3A87), Theme.hex(0xFE9E46)]
    }
}

/// Startup splash artwork (DECISIONS 2026-10-14): a fixed dark composition, identical in Light and Dark appearance.
extension Theme {
    public enum Splash {
        public static let size = CGSize(width: 800, height: 500)
        public static let fieldX: CGFloat = 420
        public static let backgroundTop = Theme.hex(0x1D1D21)
        public static let backgroundBottom = Theme.hex(0x151518)
        public static let version = Theme.hex(0x9C9CA2)
        public static let credit = Theme.hex(0x6F6F76)
        public static let title = Theme.hex(0xF2F2F5)
        public static let status = Theme.hex(0x9C9CA2)
        public static var statusFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .regular) }
        /// Accent in the dark palette.
        public static let accent = Theme.hex(0xA56BFF)
        /// Mini timeline card (the progress display): fill, 1 px border, ruler ticks, ruler line.
        public static let cardFill = Theme.hex(0x222227)
        public static let cardBorder = Theme.white(0.07)
        public static let rulerTick = Theme.white(0.22)
        public static let rulerLine = Theme.white(0.18)
        public static let clipBorder = Theme.white(0.15)
        /// Clip gradient colors (top, bottom) of the app icon.
        public static let clipOrange = (top: Theme.hex(0xFDA54D), bottom: Theme.hex(0xE88A38))
        public static let clipPink = (top: Theme.hex(0xEF3A87), bottom: Theme.hex(0xC92A6E))
        public static let clipRose = (top: Theme.hex(0xE5717F), bottom: Theme.hex(0xC85A68))
        public static let clipViolet = (top: Theme.hex(0x8727C7), bottom: Theme.hex(0x6E1FA5))
        public static let clipDeep = (top: Theme.hex(0x7516B0), bottom: Theme.hex(0x5D1090))
        public static let clipRed = (top: Theme.hex(0xEE456F), bottom: Theme.hex(0xCC345A))
        public static let pipTop = Theme.hex(0xFFFFFF)
        public static let pipBottom = Theme.hex(0xC3C9D9)
        public static let pipEdge = Theme.hex(0x8D93A8, alpha: 0.6)
        public static let pipFace = Theme.hex(0x17171B)
        public static let pipCheek = Theme.hex(0xFF8FA3, alpha: 0.55)
    }
}
