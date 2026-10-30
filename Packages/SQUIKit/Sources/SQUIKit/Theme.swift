import AppKit
import SQCore

/// Design tokens from docs/DESIGN.md. Surface, text, fill and line colors follow the Appearance setting
/// (`ThemeAppearance`, Dark / Light, Background, Contrast): they resolve from the live `AppearancePalette`, never from
/// system colors. Clip, picture and status colors are fixed sRGB values.
public enum Theme {
    /// Builds an sRGB color from 0xRRGGBB and an alpha.
    public static func hex(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
    public static func white(_ alpha: CGFloat) -> NSColor { hex(0xFFFFFF, alpha: alpha) }
    public static func black(_ alpha: CGFloat) -> NSColor { hex(0x000000, alpha: alpha) }
    /// Neutral gray of `level` (0 black ... 1 white) at `alpha`.
    public static func gray(_ level: CGFloat, alpha: CGFloat) -> NSColor { NSColor(white: level, alpha: alpha) }
    /// `c` blended 11 % toward white (board clip edge: a 0.5 px line of white at 22 %, drawn 1 pt wide) (clip edge from its fill).
    static func lift(_ c: NSColor) -> NSColor { c.blended(withFraction: 0.11, of: hex(0xFFFFFF)) ?? c }

    /// `c` with black at `amount` laid over it, computed on the sRGB components (board `.bd` body shade).
    static func shade(_ c: NSColor, by amount: CGFloat) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c, k = 1 - amount
        return NSColor(srgbRed: s.redComponent * k, green: s.greenComponent * k, blue: s.blueComponent * k, alpha: s.alphaComponent)
    }

    public enum Colors {
        /// Board "Media offline" label on a flat offline clip.
        public static let offlineText = Theme.hex(0xFF8A80)
        /// Board `.thh` empty thumbnail well.
        public static let thumbWell = Theme.dynamic { $0.isDark ? PaletteColor(hex: 0x2A2A2A) : $0.content.over(.black, 0.06) }
        // Surfaces (design artifact v11, sq.css `.sq` vars): grays carry a ~3 unit blue lean (friendlier, 2026-10-04 DECISIONS).
        public static let titlebar = Theme.dynamic { $0.titlebar }
        public static let panel = Theme.dynamic { $0.panel }
        public static let content = Theme.dynamic { $0.content }
        public static let rowAlt = Theme.ink(0.025)
        public static let viewer = Theme.hex(0x0C0C0C)
        public static let timeline = Theme.dynamic { $0.timeline }
        public static let lane = Theme.dynamic { $0.lane }
        /// Area around and behind the Program / Source / Color picture (the picture's own black stays black): neutral #2C2C2C,
        /// 1.5:1 over black, so the frame edge is visible. Must equal `Presenter.surround` (SQRender).
        public static let monitorBackdrop = Theme.hex(0x2C2C2C)
        /// Split between panels (sq.css `--div`): #0b0b0b, not black.
        public static let divider = Theme.dynamic { $0.divider }
        /// Behind the panels (start screen, panel gaps): #141416 in dark, follows Background only.
        public static let canvas = Theme.dynamic { $0.canvas }
        public static let separator = Theme.inkLine(0.065)
        // Text. Opaque on purpose (design v11 values composited over the panel #1a1a1a: .88 -> E3, .62 -> A8, .52 -> 91): AppKit
        // draws white-with-alpha text brighter and heavier than the board (measured: peak 252 vs 227 on the Library sidebar).
        // Disabled dimming multiplies `alphaComponent`, which is now 1.
        public static let label = Theme.dynamic { $0.label }
        public static let label2 = Theme.dynamic { $0.label2 }
        public static let label3 = Theme.dynamic { $0.label3 }
        // Fills and controls
        public static let fill = Theme.inkFill(0.11)
        public static let fill2 = Theme.inkFill(0.06)
        public static let fillHover = Theme.inkFill(0.16)
        public static let fillPressed = Theme.inkFill(0.22)
        public static let field = Theme.dynamic { PaletteColor.black.withAlpha($0.isDark ? 0.28 : 0.05) }
        public static let fieldEdge = Theme.inkFill(0.10)
        /// Field edge on hover (text, search and scrub fields).
        public static let fieldEdgeHover = Theme.inkFill(0.18)
        public static let selection = Theme.dynamic { $0.ink.withAlpha($0.isDark ? 0.14 : 0.08) }
        // Accent
        public static let accent = Theme.dynamic { $0.accent }
        public static let accentFill = Theme.dynamic { $0.accentFill }
        /// Accent used as text on a panel (v9 `--accentText`: the timecode under the monitor).
        public static let accentText = accent
        /// Size badge on the monitor picture (v9 `.mbadge`): black 72 % pill, text #D0D0D0.
        public static let pictureBadge = Theme.black(0.72)
        public static let pictureBadgeText = Theme.hex(0xD0D0D0)
        /// The Support heart and its filled button (pink, close to #EA4AAA). Used only for Support entries.
        public static let support = Theme.hex(0xEA4AAA)
        /// Slider knob (sq.css `.sl b`): #f2f2f2, white on hover / drag.
        public static let sliderKnob = Theme.hex(0xF2F2F2)
        public static let sliderKnobActive = Theme.hex(0xFFFFFF)
        /// Popup chevron stroke (sq.css `.pop:after`, #999).
        public static let chevron = Theme.dynamic { $0.isDark ? PaletteColor(hex: 0x999999) : $0.label3 }
        public static let accentRing = Theme.dynamic { $0.accent.withAlpha(0.45) }
        public static let accentTint = Theme.dynamic { $0.accent.withAlpha($0.isDark ? 0.22 : 0.16) }
        /// V1 Quiet: 1 px outline just inside the focused panel group.
        public static let focusRing = Theme.dynamic { $0.accent.withAlpha($0.isDark ? 0.55 : 0.45) }
        /// Text on the viewer picture (scrub HUD) sits on this backdrop.
        public static let viewerHUD = Theme.black(0.55)
        /// Safe-margin guides over the picture.
        public static let guide = Theme.white(0.55)
        /// Platform UI mock (zone popup preview) over the picture: shapes and glyphs.
        public static let platformMock = Theme.white(0.62)
        /// Warning text in the status bar (Linked Selection off).
        public static let warning = Theme.dynamic { $0.warning }
        // Status
        public static let red = Theme.dynamic { $0.red }
        public static let green = Theme.hex(0x30D158)
        public static let yellow = Theme.hex(0xFFD60A)
        // Clips
        /// Clip fills per type (sq.css `.clip`, `.a`, `.t`, `.c`, `.n`, `.adj`). Edges are the fill lifted 11 % toward white.
        public static let clipVideo = Theme.hex(LabelColor.videoDefault.rgb)
        public static let clipVideoEdge = Theme.lift(clipVideo)
        public static let clipAudio = Theme.hex(LabelColor.audioDefault.rgb)
        public static let clipAudioEdge = Theme.lift(clipAudio)
        public static let clipAudioWave = Theme.hex(0x9FD98A)
        public static let clipNest = Theme.hex(LabelColor.nestedDefault.rgb)
        public static let clipNestEdge = Theme.lift(clipNest)
        public static let clipTitle = Theme.hex(LabelColor.textDefault.rgb)
        public static let clipTitleEdge = Theme.lift(clipTitle)
        public static let clipCaption = Theme.hex(LabelColor.captionDefault.rgb)
        public static let clipCaptionEdge = Theme.lift(clipCaption)
        /// Design v9 `--c-capword`: the word boxes on the captions lane.
        public static let clipCaptionWord = Theme.hex(0x7F591B)
        public static let clipAdjustment = Theme.hex(LabelColor.generatorDefault.rgb)
        public static let clipAdjustmentEdge = Theme.lift(clipAdjustment)
        /// Photos / stills and folders have no token of their own: the Project panel and the timeline both read `LabelColor`
        /// (`imageDefault`, `binDefault`). Only the folder keeps one, for panel chrome.
        public static let clipFolder = Theme.hex(LabelColor.binDefault.rgb)
        public static let clipShade = Theme.black(0.22)
        public static let onClip = Theme.hex(0xFFFFFF)
        public static let clipSelect = Theme.hex(0xFFFFFF)
        /// Snap indicator line (timeline and playhead drags).
        public static let snapLine = Theme.hex(0xFFD60A)
        /// Fast Cut skimmer (hover playhead): a lighter yellow than the snap line, 2 pt like the playhead.
        public static let skimmer = Theme.hex(0xFFE566)
        // Timeline furniture
        public static let playhead = Theme.dynamic { $0.isDark ? PaletteColor.white.withAlpha(0.92) : PaletteColor(hex: 0x19191C, alpha: 0.92) }   // design draws it white (sq.css `.phd`)
        public static let keyframe = Theme.dynamic { $0.keyframe }
        /// Selected keyframe diamond (sq.css `.kf.sel`): accent blue.
        public static let keyframeSelected = accent
        /// A Magic mask's tracked frame in the keyframe lanes: smaller (`ControlsMetrics.trackedKeyScale`) and dimmer than a key.
        public static let keyframeTracked = label3
        /// In/Out range over the ruler and lanes (sq.css `.io`): tint plus 2 px edges. Boards: accent tint + accent edge.
        public static let inOutTint = accentTint
        public static let inOutEdge = accent
        /// Neutral In/Out wash for rows that are not the ruler (white 6 %).
        public static let inOutWash = Theme.white(0.06)
        /// Hairline under each track row / lane (sq.css `.trk .lane`, white 9 %) and under track headers (12 %).
        public static let trackRowLine = Theme.inkLine(0.09)
        public static let trackHeaderLine = Theme.inkLine(0.12)
        /// Every second property row in the Controls keyframe area (white 2.5 %).
        public static let marker = Theme.hex(0xFF9F0A)
        public static let range = Theme.white(0.07)
        public static let rangeEdge = Theme.white(0.55)
        // Graph curves
        public static let curveX = Theme.hex(0xFF9F0A)
        public static let curveY = Theme.hex(0x64D2FF)
        // Overlays
        /// D4 quiet layers: the one opaque color of everything that floats (menus, popups, popovers, dialogs, sheets).
        public static let overlay = Theme.dynamic { $0.overlay }
        /// One edge for every floating layer (menus, popovers, dialogs, tooltips, Quick Apply, splash): 0.5 pt white 14 %
        /// (`Overlay.edgeWidth`). Was 1 pt white 9 % on popovers and 0.5 pt white 14 % on menus / dialogs / tooltips.
        public static let overlayEdge = Theme.ink(0.14)
        public static let overlayHover = Theme.inkFill(0.08)
        public static let scrim = Theme.black(0.38)
        /// Tooltip hairline (sq.css `.tip`): white 14 %.
        public static let tooltipEdge = overlayEdge
        /// Badge on the picture (sq.css `.vbadge`): rgba(40,40,40,.85).
        public static let viewerBadge = Theme.hex(0x282828, alpha: 0.85)
        // Rulers and graphs in the Controls panel (sq.css `.ruler`, `.epane`, build.py `egraph`)
        public static let rulerLine = Theme.inkLine(0.28)
        public static let rulerMinor = Theme.inkLine(0.16)
        public static let graphGrid = Theme.white(0.06)
        public static let graphBaseline = Theme.white(0.14)
        public static let graphHandleLine = Theme.white(0.60)
        public static let graphPane = Theme.white(0.03)
        // Wells
        /// Audio meter bar track (sq.css `.meter .bar`).
        public static let meterTrack = Theme.hex(0x0A0A0A)
        /// Scope plot box.
        public static let scopeBox = Theme.hex(0x0A0A0A)
        /// Thumbnail tile background (sq.css `.tile .tn`).
        public static let tileBackground = Theme.dynamic { $0.isDark ? PaletteColor(hex: 0x222222) : $0.content.over(.black, 0.04) }
    }

    /// D4 floating-layer metrics and the shared layer styling.
    public enum Overlay {
        public static let rowHeight: CGFloat = Theme.Menu.rowHeight
        /// Hairline width of `Colors.overlayEdge`.
        public static let edgeWidth: CGFloat = 0.5
        /// Opaque fill, hairline edge, radius 10 (design B `--r-menu`) on a view's layer.
        @MainActor public static func style(_ layer: CALayer?) {
            layer?.backgroundColor = Colors.overlay.cgColor
            layer?.cornerRadius = Radius.menu
            layer?.cornerCurve = .continuous
            layer?.borderWidth = edgeWidth
            layer?.borderColor = Colors.overlayEdge.cgColor
            layer?.masksToBounds = true
        }
    }

    // Type: `Theme.Typography` (ThemeTokens.swift). The old `Theme.Fonts` set (13 semibold, 18 light, 9) is gone.

    /// Spacing scale in pt.
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        /// One nesting step of every tree / outline list (Library tree, Effects folders, Project folders).
        public static let treeIndent: CGFloat = 14
        /// Icon to label.
        public static let iconToLabel: CGFloat = 6
        /// Design B: panels are cards 2 pt apart (also the margin around the workspace); no divider line.
        public static let paneDivider: CGFloat = 2
        /// Inset of the first tab from the strip edge and of the HUD from the picture corner.
        public static let inset: CGFloat = 6
        public static let scale: [CGFloat] = [xxs, xs, sm, md, lg, xl]
    }

    /// Corner radii in pt (DESIGN-SYSTEM 1.5, board v11): 0 / 3 (panel cards) / 4 / 6 / 8; control 6, inner 4 (design B).
    /// No capsules, no radius above 8.
    public enum Radius {
        /// Panes, sequence tabs: hard edged (docked panels use `panel`).
        public static let none: CGFloat = 0
        /// Design B: the corner of every docked panel card (the gap between cards shows `divider`).
        public static let panel: CGFloat = 3
        /// Chips, checkbox, swatch, clip, slider track, inner highlight inside an overlay.
        public static let small: CGFloat = 4
        /// Buttons, popups, fields, segmented, tool buttons, grid tiles and their selection (design v7: 6).
        public static let control: CGFloat = 6
        /// Shapes inside a control: the selected segment, an inner highlight (design v7: 4).
        public static let inner: CGFloat = 4
        /// D4: the one radius of every floating layer (menus, popovers, dialogs, sheets, cards).
        public static let overlay: CGFloat = 8
        /// Design B `--r-menu`: menus, popovers and the layers that float like them (inset 4 + item 6).
        public static let menu: CGFloat = 10
        public static let scale: [CGFloat] = [none, small, control, overlay]
        /// Checkbox / radio-box corner (sq.css `.chk`).
        public static let checkbox: CGFloat = 4
        /// Multi-line boxes, lists, wells.
        public static let well: CGFloat = 8
        /// Capsule radius for a control of `height` (22 -> 11).
        public static func capsule(forHeight h: CGFloat = Metrics.capsule) -> CGFloat { h / 2 }

        // Old names, kept so call sites build until each area is migrated (same values as the new tokens).
        @available(*, deprecated, renamed: "small") public static let clip: CGFloat = small
        @available(*, deprecated, renamed: "small") public static let row: CGFloat = small
        @available(*, deprecated, renamed: "small") public static let check: CGFloat = small
        @available(*, deprecated, renamed: "control") public static let field: CGFloat = control
        @available(*, deprecated, renamed: "overlay") public static let card: CGFloat = overlay
        @available(*, deprecated, renamed: "none") public static let window: CGFloat = none
    }

    /// A template icon from the one icon set (`SQIcon`) at `size` points. `size` defaults to the 13 pt chrome size.
    /// A label makes a private copy that carries the accessibility description (the cached image stays shared).
    public static func symbol(_ icon: SQIcon, size: CGFloat = 13, label: String? = nil) -> NSImage? {
        let image = icon.image(size: size)
        guard let label else { return image }
        let copy = image.copy() as? NSImage ?? image
        copy.accessibilityDescription = label
        return copy
    }

    public enum Metrics {
        /// Top bar (v9 `.top`): 44, own view (replaces the NSToolbar).
        public static let topBar: CGFloat = UIScale.scaled(44)
        public static let statusBar: CGFloat = UIScale.scaled(28)
        public static let panelHeader: CGFloat = UIScale.scaled(30)
        // Row heights: `Theme.Row` (list / property 24, thumb 28). Old listRow 22, effectsRow 28, controlHeight 20 are gone.
        public static let pushButton: CGFloat = UIScale.scaled(22)
        // Tracks
        public static let trackV1: CGFloat = UIScale.scaled(40)
        public static let trackA1: CGFloat = UIScale.scaled(32)
        public static let trackOther: CGFloat = UIScale.scaled(20)
        /// Design v9 `.tlmain`: 156 pt header column.
        public static let trackHeader: CGFloat = UIScale.scaled(156)
        /// No tool column inside the timeline view (the tool bar is docked beside it): width 0. Track headers start at x = 0.
        public static let toolColumn: CGFloat = 0
        /// V1 Quiet custom controls: SQButton / SQPopup height, SQSegmented and search field height, SQCheckbox side.
        /// v6 shape rule: buttons, popups, segments and single-line fields are capsules, 22 high.
        public static let quietButton: CGFloat = UIScale.scaled(22)
        public static let quietField: CGFloat = UIScale.scaled(22)
        public static let capsule: CGFloat = UIScale.scaled(22)
        public static let checkbox: CGFloat = 14
        /// Slider (sq.css `.sl`): 10 px knob, 2 px track.
        public static let sliderKnob: CGFloat = 10
        public static let sliderTrack: CGFloat = 2
        /// Monitor header, and the v9 transport block under the picture (`.mtr`: 8 + scrub 16 + 6 + row 28 + 8).
        public static let monitorHeader: CGFloat = UIScale.scaled(32)
        public static let monitorFooter: CGFloat = UIScale.scaled(66)
        /// Listening level strip under the audio meter: strip height, slider max width / height, Dim button size.
        public static let monitorStrip: CGFloat = 44
        public static let monitorSliderMaxWidth: CGFloat = 80
        public static let monitorSliderHeight: CGFloat = 14
        public static let monitorDimWidth: CGFloat = 22
        public static let monitorDimHeight: CGFloat = 18
        /// Scrub strip under the viewer.
        public static let scrubBar: CGFloat = UIScale.scaled(16)
        /// Sequence tab row above the timeline.
        public static let sequenceTabs: CGFloat = UIScale.scaled(24)
        /// Status bar text line and export ring.
        public static let statusLine: CGFloat = 14
        /// Accent underline of the selected panel tab, and focus ring width.
        public static let tabUnderline: CGFloat = 2
        public static let focusRingWidth: CGFloat = 1
        /// Top bar controls.
        public static let barControl: CGFloat = UIScale.scaled(22)
        public static let barIconWidth: CGFloat = 24
        public static let workspacePopupWidth: CGFloat = 132
    }
}
