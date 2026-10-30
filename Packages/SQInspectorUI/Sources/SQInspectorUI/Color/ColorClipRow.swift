import Foundation
import SQCore

/// The grade state of a clip as the Sources tiles say it ("Simple", "Pro", "No grade", ...).
public struct ColorClipRow: Equatable, Sendable {
    public var id: Clip.ID
    public var media: UUID?
    public var name: String
    /// "Simple", "Pro", "Simple on, Pro kept", "Pro on, Simple kept", "No grade".
    public var grade: String
    /// 1-based place in the sequence.
    public var index: Int

    /// What the second line says about a clip's two grades: which one is active and whether the other is kept.
    public static func gradeText(hasSimple: Bool, graph: ColorGraph?) -> String {
        guard let graph else { return hasSimple ? "Simple" : "No grade" }
        if graph.isActive { return hasSimple ? "Pro on, Simple kept" : "Pro" }
        return hasSimple ? "Simple on, Pro kept" : "Pro kept, off"
    }

    /// The picture clips of `timeline` in timeline order.
    public static func rows(_ timeline: Timeline?) -> [ColorClipRow] {
        guard let timeline else { return [] }
        return ColorViewerHeaderContent.clips(timeline).enumerated().map { i, c in
            ColorClipRow(id: c.id, media: c.media, name: c.name,
                         grade: gradeText(hasSimple: !c.colorGradeEffects.isEmpty, graph: c.colorGraph), index: i + 1)
        }
    }
}
