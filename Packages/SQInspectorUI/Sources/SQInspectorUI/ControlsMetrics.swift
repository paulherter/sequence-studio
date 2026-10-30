import Foundation
#if canImport(AppKit)
import SQUIKit
#endif

/// Controls panel geometry, from the design source (docs/design-source/sq.css: `.grp`, `.fx`, `.kp`, `.kr`, `.epane`,
/// `.eg`; build.py: `m_fx`, `m_kp`, `m_kr`, `epane`, `egraph`). One place for the property column and the keyframe lanes,
/// so a row on the left is exactly as tall as its lane on the right. The row heights are portable (the layout of
/// `EffectControlsModel` reads them on Windows too); columns and glyph sizes are in EffectControlsParts.swift.
public enum ControlsMetrics {
    /// Space between two sections: none, v9 stacks the section rows on the row pitch (`.ksec`).
    public static let sectionGap: CGFloat = 0
    /// The crossover strip of the multiband compressor in the Audio section (`MultibandEditor.rowHeight`).
    public static let multibandRow: CGFloat = 32
    #if canImport(AppKit)
    /// Clip line under the panel header (v9 `.clhead`): icon, clip name, "Sequence · Track · in – out".
    public static let clipLine: CGFloat = Theme.Row.panelHeader
    /// Column header row (v9 `.kg.khead`): "Property" at the left, the mini ruler of the keyframe area at the right.
    public static let header: CGFloat = Theme.Row.standard
    /// VIDEO / AUDIO group label (`.grp`, `.kr.g`).
    public static let group: CGFloat = ControlsGrid.headerHeight
    /// Effect section row (`.fx`, `.kr.s`), separator at its top.
    public static let section: CGFloat = ControlsGrid.headerHeight
    /// Parameter row (`.kp`, `.kr`): one height for every row, whatever control it holds.
    public static let parameter: CGFloat = ControlsGrid.rowHeight
    public static let tallParameter: CGFloat = ControlsGrid.rowHeight
    /// Opened keyframe row (`.epane`, `.eg`).
    public static let graph: CGFloat = Theme.Inspector.graphHeight
    #else
    public static let clipLine = Portable.clipLine, header = Portable.header, group = Portable.group
    public static let section = Portable.section, parameter = Portable.parameter
    public static let tallParameter = Portable.parameter, graph = Portable.graph
    #endif

    /// Key glyphs in the lanes (v9 `.dm`): a 9 pt square with 1.5 pt corners turned 45 degrees (linear), a 10 pt
    /// circle (eased), a 9 pt square (hold); each with a 1.5 pt ring in the lane color.
    static let keySide: CGFloat = 9
    static let keyRing: CGFloat = 1.5
    /// The animate toggle of a parameter row (v9 `.kfb`): a smaller diamond than the lane keys.
    static let toggleSide: CGFloat = 7
    /// A Magic mask's tracked frame in the lanes: this share of `keySide` (`Theme.Colors.keyframeTracked`).
    static let trackedKeyScale: CGFloat = 0.6
    /// Key glyphs of the speed graph (`.eg .kd`) and its handle dots (`.eg .hd`).
    static let graphKeySide: CGFloat = 8
    static let handleDot: CGFloat = 7

    // shortcut: the Mac `Theme` values at UI scale 1 (SQUIKit's Theme is AppKit), used off the Mac;
    // ControlsMetricsPortableTests checks they match. Upgrade when SQUIKit's tokens move into a portable file.
    public enum Portable {
        public static let clipLine: CGFloat = 30
        public static let header: CGFloat = 24
        public static let group: CGFloat = 26
        public static let section: CGFloat = 26
        public static let parameter: CGFloat = 26
        public static let graph: CGFloat = 120
        /// `Theme.Inspector.popupWidth`: Blend Mode and choice popups.
        public static let popupWidth: CGFloat = 120
    }
}

extension EffectControlsModel {
    /// The Parametric EQ's "Curve" group key and the height of its open curve (EffectControlsEQ.swift).
    nonisolated static let eqCurveKey = "eq-curve"
    nonisolated public static let eqCurveHeight: CGFloat = 170
}
