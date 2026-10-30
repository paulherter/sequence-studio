import Foundation
import SQCore
import SQText

/// Sequence > Change Format… and Duplicate as Format… as session calls: the Mac sheet (App SequenceSettingsSheet) and the
/// portable shell dialog (SQDrawShell ShellFormat) run the same conform.
extension EditorSession {
    /// Text block size at Scale 100 % for the conform (SQCore cannot lay out text). nil for clips that are not text.
    public static func conformTextBlock(_ clip: Clip) -> SequenceConform.TextBlock? {
        guard let ref = clip.generator, ref.kind == GeneratorRef.text, let (template, _) = try? TextGenerator.decode(ref) else { return nil }
        let layout = TextLayout.layout(text: template.text, style: template.style, maxWidth: template.box?.width,
                                       boxHeight: template.box?.height)
        guard !layout.lines.isEmpty else { return nil }
        let b = layout.bounds, ink = layout.inkBounds
        return SequenceConform.TextBlock(width: b.width, height: b.height,
                                         inkOffset: Vec2((ink.x + ink.width / 2) - (b.x + b.width / 2),
                                                         (ink.y + ink.height / 2) - (b.y + b.height / 2)))
    }

    /// The per-clip modes of the dialog's "Selected Clips" choice (nil = same as all clips).
    public func conformOverrides(selectedMode: ConformMode?) -> [Clip.ID: ConformMode] {
        guard let m = selectedMode else { return [:] }
        return Dictionary(uniqueKeysWithValues: selection.map { ($0, m) })
    }

    /// Change Format of the active sequence as one undo step. False when there is nothing to change or it failed
    /// (`lastError` is not set; the caller flashes).
    @discardableResult
    public func changeActiveFormat(to format: SequenceFormat, mode: ConformMode, selectedMode: ConformMode?) -> Bool {
        guard let tl = activeTimeline, format != tl.format else { return false }
        let overrides = conformOverrides(selectedMode: selectedMode)
        do {
            try perform("Change Format") {
                try $0.changeFormat(of: tl.id, to: format, mode: mode, overrides: overrides, textSize: Self.conformTextBlock)
            }
        } catch { return false }
        return true
    }

    /// Duplicate as Format: a conformed copy of the active sequence (one undo step), opened. `name` empty = automatic
    /// (name + shape). nil when it failed.
    @discardableResult
    public func duplicateActiveSequence(as format: SequenceFormat, mode: ConformMode, selectedMode: ConformMode?,
                                        name: String) -> Timeline.ID? {
        guard let tl = activeTimeline else { return nil }
        let overrides = conformOverrides(selectedMode: selectedMode)
        let typed = name.trimmingCharacters(in: .whitespaces)
        var newID: Timeline.ID?
        do {
            try perform("Duplicate as Format") {
                newID = try $0.duplicateSequence(tl.id, as: format, mode: mode, overrides: overrides,
                                                 name: typed.isEmpty ? nil : typed, textSize: Self.conformTextBlock)
            }
        } catch { return nil }
        if let newID { setActiveTimeline(newID) }
        return newID
    }
}

/// F7.3: the Pixel Aspect choices of Project media (context menu and Clip > Pixel Aspect), without UI: the Mac
/// `PixelAspectMenu` (SQEditorUI) and the portable shell build their rows from these.
public enum PixelAspectChoices {
    /// What the selected media items say now: the file's own shape and the shape chosen, per item.
    public struct State: Equatable, Sendable {
        public var files: [PixelAspect]
        public var overrides: [PixelAspect?]
        public init(files: [PixelAspect], overrides: [PixelAspect?]) { self.files = files; self.overrides = overrides }

        /// The file's ratio when every item agrees; nil for a mixed selection.
        public var sharedFile: PixelAspect? { Set(files).count == 1 ? files.first : nil }
        public var fromFile: Bool { overrides.allSatisfy { $0 == nil } }
        /// The chosen ratio when every item has the same choice.
        public var sharedChoice: PixelAspect? { Set(overrides.map { $0 as PixelAspect? }).count == 1 ? overrides.first ?? nil : nil }
        /// The shared choice when it is none of the named ratios.
        public var customChoice: PixelAspect? { sharedChoice.flatMap { c in named.contains { $0.aspect == c } ? nil : c } }
    }

    /// The state of `media`; nil unless every item is media with a picture.
    public static func state(project: Project, media: [MediaRef.ID]) -> State? {
        let videos = media.compactMap { project.media($0)?.info?.video }
        guard !media.isEmpty, videos.count == media.count else { return nil }
        return State(files: videos.map(\.pixelAspect), overrides: videos.map(\.pixelAspectOverride))
    }

    /// Named ratios: the DV and HD cases first, then the lens squeeze factors the model offers.
    public static let named: [(title: String, aspect: PixelAspect)] = {
        func p(_ n: Int, _ d: Int) -> PixelAspect { PixelAspect(n, d) ?? .square }
        var rows: [(String, PixelAspect)] = [
            ("Square", .square),
            ("DV NTSC 4:3", p(10, 11)), ("DV NTSC 16:9", p(40, 33)),
            ("DV PAL 4:3", p(59, 54)), ("DV PAL 16:9", p(118, 81)),
            ("HD 1440 / HDV", p(4, 3))]
        for a in PixelAspect.presets where !rows.contains(where: { $0.1 == a }) {
            rows.append(("Anamorphic \(ratioText(a))", a))
        }
        return rows
    }()

    /// "1.33", "0.909": three significant digits at most, no trailing zeros.
    public static func ratioText(_ a: PixelAspect) -> String {
        let s = String(format: a.value < 1 ? "%.3f" : "%.2f", a.value)
        guard s.contains(".") else { return s }
        var t = Substring(s)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return String(t)
    }

    public static func title(_ a: PixelAspect) -> String {
        named.first { $0.aspect == a }.map { "\($0.title) (\(ratioText(a)))" } ?? "Custom (\(ratioText(a)))"
    }

    /// The typed ratio range of the Custom dialog.
    public static let ratioRange: ClosedRange<Double> = 0.25...4

    /// A pixel aspect from a typed ratio (width / height of one pixel); nil when not positive.
    public static func aspect(fromRatio v: Double) -> PixelAspect? {
        guard v.isFinite, v > 0 else { return nil }
        return PixelAspect(Int((v * 10_000).rounded()), 10_000)
    }
}
