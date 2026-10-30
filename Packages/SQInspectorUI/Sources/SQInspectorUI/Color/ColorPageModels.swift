import Foundation
import SQCore

// Portable value types of the Color page (moved from the AppKit views: ColorTargetBarView, ColorClipListView,
// ColorPageChrome) so the Mac views and the shared draw-list Color page (SQInspectorUI/Draw) use the same code.

/// What the Color panel grades, described (built by the panel from its target): its name, whether it shares its
/// source's grade, and what the monitor shows instead of it.
struct ColorTargetBarContent: Equatable {
    var title: String
    /// nil = no Linked toggle (a source with one cut, adjustment layers, the whole sequence).
    var linked: Bool?
    /// "On screen: X" when the monitor shows another clip than the target.
    var onScreen: String?

    /// A clip: while Linked it stands for its source file (named by the file), else for itself. The Linked toggle shows
    /// only when the source has more than one cut in the project.
    static func clip(_ c: Clip, project: Project) -> ColorTargetBarContent {
        guard c.isSourceGradeable else { return ColorTargetBarContent(title: c.name) }
        var cuts = 0
        for t in project.timelines { for tr in t.tracks { cuts += tr.clips.count(where: { $0.media == c.media && $0.isSourceGradeable }) } }
        let linked = project.isGradeLinkedToSource(c.id)
        let file = project.media.first { $0.id == c.media }?.name
        let title = linked ? (file ?? c.name) : c.name
        return ColorTargetBarContent(title: title, linked: cuts > 1 || c.gradeIndependent ? linked : nil)
    }

    static func wholeSequence(_ t: Timeline) -> ColorTargetBarContent { ColorTargetBarContent(title: "Whole sequence") }
}

/// The shape of the sequence the Color page lays itself out for (DECISIONS 2026-10-03 "Color grading UI").
public enum ColorPageFormat: String, Codable, Sendable, Equatable {
    case landscape, portrait, square

    /// Square when the sides differ by under 5 %, portrait when taller than wide, else landscape.
    public init(width: Int, height: Int) {
        guard width > 0, height > 0 else { self = .landscape; return }
        let r = Double(width) / Double(height)
        if r >= 0.95 && r <= 1.05 { self = .square } else if height > width { self = .portrait } else { self = .landscape }
    }

    public init(_ f: SequenceFormat?) { self = f.map { ColorPageFormat(width: $0.width, height: $0.height) } ?? .landscape }
}

/// How often a source is used in the sequence ("1 use", "3 uses"), as the Clips strip and the Color header show it.
public enum ColorUses {
    public static func text(_ n: Int) -> String { n == 1 ? "1 use" : "\(n) uses" }

    /// The line under a tile's name: the uses, then the grade state ("2 uses \u{00B7} Pro", "1 use \u{00B7} No grade").
    public static func tileLine(uses n: Int, grade: String) -> String { "\(text(n)) \u{00B7} \(grade)" }
}

/// What the viewer of the Color page shows: the graded picture, the ungraded one, or both side by side.
public enum ColorCompareMode: Int, Sendable, CaseIterable {
    case before, after, split

    public var title: String {
        switch self {
        case .before: "Before"
        case .after: "After"
        case .split: "Split"
        }
    }
}

/// What the viewer header of the Color page names (pure, tested): the clip being graded and its place among the
/// picture clips of the sequence ("4 of 6", in timeline order: start, then the upper track first).
public struct ColorViewerHeaderContent: Equatable, Sendable {
    public var name: String
    /// "n of m"; nil for the sequence-wide grade, an adjustment layer or no target.
    public var position: String?

    public init(name: String, position: String? = nil) { self.name = name; self.position = position }

    /// The picture clips of `timeline` that take a grade of their own, in timeline order.
    public static func clips(_ timeline: Timeline) -> [Clip] {
        var cuts: [(Time, Int, Clip)] = []
        for (k, tr) in timeline.tracks.enumerated() where tr.kind == .video {
            for c in tr.clips where c.acceptsColor && !c.isSequenceGrade && !c.isAdjustment { cuts.append((c.start, -k, c)) }
        }
        cuts.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return cuts.map(\.2)
    }

    public static func make(_ target: ColorTargetResolution, timeline: Timeline?) -> ColorViewerHeaderContent {
        guard let timeline else { return ColorViewerHeaderContent(name: "") }
        switch target {
        case .message: return ColorViewerHeaderContent(name: timeline.name)
        case .sequence: return ColorViewerHeaderContent(name: "Whole sequence")
        case .clip(let id):
            let all = clips(timeline)
            if let i = all.firstIndex(where: { $0.id == id }) {
                return ColorViewerHeaderContent(name: all[i].name, position: "\(i + 1) of \(all.count)")
            }
            let c = timeline.tracks.lazy.flatMap(\.clips).first { $0.id == id }
            return ColorViewerHeaderContent(name: c?.name ?? timeline.name)
        }
    }
}

extension ColorCompareMode {
    /// The mode's name in the Color panel's Layout menu.
    public var layoutTitle: String {
        switch self {
        case .after: "Single"
        case .before: "Before"
        case .split: "Before and after"
        }
    }
}

/// Number texts of the Color rows (the Mac `ColorParamRow` and the draw-list Color page).
public enum ColorValueText {
    /// How a value reads in the value column (version 9): the bare number, no plus sign and no unit ("8", "-18", "100").
    public static func text(_ v: Double, decimals: Int) -> String {
        let step = pow(10, Double(decimals))
        let r = (v * step).rounded() / step
        return r == 0 ? String(format: "%.\(decimals)f", 0.0) : String(format: "%.\(decimals)f", r)
    }

    /// The text while typing: the value at the row's full precision, without trailing zeros ("8.4", "8").
    public static func editText(_ v: Double, decimals: Int) -> String {
        var s = text(v, decimals: decimals)
        guard s.contains(".") else { return s }
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// The summary of a folded section carries the sign ("+8", "-18", "0").
    public static func signedText(_ v: Double, decimals: Int) -> String {
        let s = text(v, decimals: decimals)
        return v > 0 && Double(s) != 0 ? "+" + s : s
    }

    /// Decimals the value column shows: whole numbers on the wide ranges (version 9), the row's own on the fine ones
    /// (Exposure in stops, the Step values). The slider, the scrub and typing keep the row's precision.
    public static func shownDecimals(range: ClosedRange<Float>, decimals: Int) -> Int {
        range.upperBound - range.lowerBound >= 100 ? 0 : decimals
    }

    /// Reads what `text` writes (and plain typed numbers).
    public static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return Double(t.hasPrefix("+") ? String(t.dropFirst()) : t)
    }
}

/// Section order and folded-section texts of the Simple grade (the Mac `ColorInspectorView`, the draw-list page).
public enum ColorSectionText {
    /// Display order (design board Color): Basic, Look, Curves, Wheels & Match, Color Range, Vignette.
    public static let order: [ColorSectionKind] = [.basicCorrection, .creative, .curves, .wheels, .zoneBoard, .hslSecondary, .vignette]

    /// What a folded section reads at its right end (version 9: "Temp +8, Exposure 0", "Vibrance +10, Saturation 100",
    /// "Luma", "Shadows, Midtones, Highlights", "Off").
    public static func summary(_ kind: ColorSectionKind, channel: Int, effect e: ColorEffect) -> String {
        func n(_ p: ColorParam) -> String {
            let v = Double(p.read(e)), d = ColorValueText.shownDecimals(range: p.range, decimals: p.decimals)
            return p.neutral == 0 ? ColorValueText.signedText(v, decimals: d) : ColorValueText.text(v, decimals: d)
        }
        switch kind {
        case .basicCorrection: return "Temp \(n(.temperature)), Exposure \(n(.exposure))"
        case .creative: return "Vibrance \(n(.creativeVibrance)), Saturation \(n(.creativeSaturation))"
        case .vignette: return ColorParam.vignetteAmount.read(e) == 0 ? "Off" : "Amount \(n(.vignetteAmount))"
        case .curves: return ["Luma", "Red", "Green", "Blue"][min(max(channel, 0), 3)]
        case .wheels: return "Shadows, Midtones, Highlights"
        case .hslSecondary: return e.hslSecondary == nil ? "Off" : "On"
        case .zoneBoard: return e.zoneBoard?.isNeutral ?? true ? "Off" : "On"
        }
    }
}
