import Foundation

/// W9.6 Adjustment Layer: a generator clip without a picture of its own. Its effects (Crop, Blur, Ultra Key, filters, masks),
/// Motion, Opacity and blend mode apply to everything composited below it on lower tracks of the same sequence, for as long
/// as it lasts. The renderer composites the layers below into one image, runs the clip's effects on it and draws that over
/// the unadjusted image with the clip's opacity and blend mode (`RenderNode.adjustment` in SQRender).
extension GeneratorRef {
    public static let adjustment = "adjustment"
    public static var adjustmentLayer: GeneratorRef { GeneratorRef(kind: adjustment, payload: Data()) }
}

extension Clip {
    public var isAdjustment: Bool { generator?.kind == GeneratorRef.adjustment }
}

extension LayerRequest {
    public var isAdjustment: Bool { generator?.kind == GeneratorRef.adjustment }
}

extension Project {
    /// Places an Adjustment Layer on a video track (overwrite, like any generator drop). Throws like `addGeneratorClip`.
    @discardableResult
    public mutating func addAdjustmentClip(in timeline: Timeline.ID, at start: Time, track: Track.ID,
                                           duration: Time) throws -> Clip.ID {
        try addGeneratorClip(kind: GeneratorRef.adjustment, payload: Data(), name: "Adjustment Layer",
                             in: timeline, at: start, track: track, duration: duration)
    }

    /// Any Adjustment Layer in any sequence (gates ProjectFile v41).
    public var containsAdjustmentClips: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains(where: \.isAdjustment) } }
    }

    /// Any clip with a blend mode a v40 build cannot decode (gates ProjectFile v41).
    public var containsExtendedBlendModes: Bool {
        timelines.contains { $0.tracks.contains { $0.clips.contains { !$0.blendMode.isLegacy } } }
    }

    /// Any clip or graphics layer with a blend mode a v54 build cannot decode (gates ProjectFile v55).
    public var containsFullBlendModes: Bool {
        let gate = ProjectFile.fullBlendVersion
        return timelines.contains { $0.tracks.contains { $0.clips.contains { c in
            c.blendMode.minimumFileVersion >= gate
                || (c.graphics?.layers.contains { $0.blendMode.minimumFileVersion >= gate } ?? false)
        } } }
    }
}
