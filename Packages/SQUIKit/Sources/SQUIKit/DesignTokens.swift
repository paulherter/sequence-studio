import Foundation

/// The one place for the design values both UIs share (the shared draw-list UI on Mac and Windows, and the AppKit `Theme`).
/// Portable: no AppKit. `DrawTheme`, `TimelineSkin` and `Theme` read these; nothing else may repeat the numbers
/// (`DesignTokensTests` fails when a copy differs, `scripts/lint-ui.sh` flags raw literals in draw code).
/// Lengths are points, unscaled (`Theme` runs them through `UIScale`, `DrawTheme` through its `scale`).
public enum SQTokens {
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
        public static let monitorStrip: Float = 44
        public static let monitorSliderMaxWidth: Float = 80
        public static let monitorSliderHeight: Float = 14
        public static let monitorDimWidth: Float = 22
        public static let monitorDimHeight: Float = 18
        public static let scrubBar: Float = 16
        public static let sequenceTabs: Float = 24
        public static let ruler: Float = 24
        public static let clipNameBand: Float = 13
        public static let paneDivider: Float = 2
        public static let pushButton: Float = 22
        public static let quietButton: Float = 22
        public static let quietField: Float = 22
        public static let barControl: Float = 22
    }
    public enum Spacing {
        public static let xxs: Float = 2, xs: Float = 4, snug: Float = 6, sm: Float = 8, md: Float = 12, lg: Float = 16
        public static let wide: Float = 20, xl: Float = 24, xxl: Float = 32
    }
    /// Radii 4/6/8/10/12 (G4).
    public enum Radius {
        public static let none: Float = 0, panel: Float = 4, small: Float = 4, control: Float = 6, overlay: Float = 8
        public static let menu: Float = 10, card: Float = 12
    }
    /// Control and list-row heights (G6).
    public enum Height {
        public static let compact: Float = 22, normal: Float = 24, large: Float = 28, panelList: Float = 24
    }
    /// Type ladder 10/11/12/13/15/18 (G3); clip names use the caption size.
    public enum TypeSize {
        public static let caption: Float = 10, body: Float = 11, list: Float = 12, title: Float = 13, heading: Float = 15
        public static let display: Float = 18, clipName: Float = caption
    }
    /// Alphas of the ink fills and lines, and of the timeline paints.
    public enum Alpha {
        public static let fill = 0.11, fillHover = 0.16, fillPressed = 0.22, fill2 = 0.06
        public static let separator = 0.065, separatorStrong = 0.11, overlayEdge = 0.12, swatchEdge = 0.18, trackRowLine = 0.09, trackHeaderLine = 0.12, rulerLine = 0.28, rulerMinor = 0.16
        public static let playhead = 0.92
        public static let guide = 0.55, viewerHUD = 0.55, platformMock = 0.62, onPictureShadow = 0.5
        public static let clipShade = 0.22, clipEdge = 0.22, thumbRule = 0.35
        public static let inOutBand = 0.13, inOutBandEdge = 0.38
        public static let cacheStrip = 0.6, transitionIssue = 0.55
        public static let badgeFill = 0.95, badgeEdge = 0.6
        public static let accentTintDark = 0.22, accentTintLight = 0.16
        public static let headOutlineLight = 0.75
        public static let selection = 0.14, rowHover = 0.08
        public static let fieldEdge = 0.10, fieldEdgeHover = 0.18
        public static let overlayEdgeWidth = 0.5
    }
    /// Artifact ink alphas (dark / light): hair, hair2, edge, current, hover.
    public enum Line {
        public static let hairDark = 0.07, hairLight = 0.08
        public static let hair2Dark = 0.11, hair2Light = 0.12
        public static let edgeDark = 0.14, edgeLight = 0.16
        public static let currentDark = 0.08, currentLight = 0.07
        public static let hoverDark = 0.05, hoverLight = 0.04
    }
    /// Fixed colors, 0xRRGGBB.
    public enum Hex {
        public static let monitorBackdrop: UInt32 = 0x2C2C2C
        public static let viewer: UInt32 = 0x0C0C0C
        public static let thumbWell: UInt32 = 0x2A2A2A
        public static let offlineClip: UInt32 = 0x5A1F1C
        public static let offlineText: UInt32 = 0xFF8A80
        public static let green: UInt32 = 0x30D158
        public static let yellow: UInt32 = 0xFFD60A
        public static let guideSnap: UInt32 = 0xFF4099
        public static let playheadLight: UInt32 = 0x19191C
        public static let headTop: UInt32 = 0xFFFFFF
        public static let headBottom: UInt32 = 0xC3C9D9
        /// Artifact surfaces (art.html :root / .light): raised (button), raisedHover, pressed, well (field, popup, check off).
        public static let raisedDark: UInt32 = 0x2E2E31, raisedLight: UInt32 = 0xFFFFFF
        public static let raisedHoverDark: UInt32 = 0x353538, raisedHoverLight: UInt32 = 0xFAFAFB
        public static let pressedDark: UInt32 = 0x262628, pressedLight: UInt32 = 0xE6E6E8
        public static let wellDark: UInt32 = 0x161618, wellLight: UInt32 = 0xEAEAEC
        public static let sliderKnob: UInt32 = 0xF2F2F4
    }
    public enum Timeline {
        public static let selectionOutlineWidth: Double = 1.5
        public static let headSize: Double = 12
    }
}
