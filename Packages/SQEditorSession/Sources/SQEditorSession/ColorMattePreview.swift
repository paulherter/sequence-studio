import Foundation
import SQCore

/// Color page, Pro grade: the monitor shows where one Step works (its qualifier and window matte) as a white overlay on
/// the picture, instead of the graded result. A viewing aid only: the engine gets a substituted timeline, the project,
/// the undo history and the export never see it (same rule as `colorSoloClip` and `ColorBypass`).
public struct ColorMattePreview: Sendable, Hashable {
    public var clip: Clip.ID
    public var step: UUID
    public init(clip: Clip.ID, step: UUID) { self.clip = clip; self.step = step }
}

extension StepPrimaries {
    /// Primaries that send every pixel to white: gain 0 and offset 1. Mixed over the picture by the Step's matte, the
    /// result is the picture where the matte is 0 and white where it is 1.
    public static var matteWhite: StepPrimaries {
        var p = StepPrimaries()
        p.gain = ColorTriple(all: 0)
        p.offset = ColorTriple(all: 1)
        return p
    }
}

extension ColorGraph {
    /// The graph the monitor renders to show the matte of step `id`: the Steps before it as they are (the qualifier
    /// reads the Step's own input), then the Step itself with its qualifier and window but a white result; later
    /// Steps and the Out LUT are left out. nil when the Step is not in the graph.
    public func matteView(of id: UUID) -> ColorGraph? {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return nil }
        var shown = Array(steps[..<i])
        var s = steps[i]
        s.enabled = true
        s.primaries = .matteWhite
        s.curves = RGBCurves()
        s.hueCurves = HueCurves()
        s.lut = nil
        shown.append(s)
        var g = ColorGraph(steps: shown, inputLUT: inputLUT, outputLUT: nil)
        g.isActive = true
        return g
    }
}

extension Timeline {
    /// This sequence with the matte view of `preview` on its clip (unchanged when the clip is not here or has no such Step).
    func showingMatte(_ preview: ColorMattePreview) -> Timeline {
        var t = self
        for ti in t.tracks.indices {
            guard var clip = t.tracks[ti].clips.first(where: { $0.id == preview.clip }) else { continue }
            guard let g = clip.colorGraph?.matteView(of: preview.step) else { return self }
            clip.colorGraph = g
            t.tracks[ti].remove(clip.id)
            guard (try? t.tracks[ti].insert(clip)) != nil else { return self }
            return t
        }
        return self
    }
}
