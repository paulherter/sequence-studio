import Foundation
import SQCore

/// What the two-up viewer shows during a Slip drag: the first and last frame of the clip as it will be after the slip.
/// The clip does not move on the timeline, its content does, so both pictures come from the preview timeline at fixed
/// sequence times (`headTime`, `tailTime`). `sourceHead` / `sourceTail` are the media times behind them, for the labels.
public struct SlipTwoUp: Sendable, Hashable {
    public var clip: Clip.ID
    /// Sequence time of the clip's first frame.
    public var headTime: Time
    /// Sequence time of the clip's last frame (never before `headTime`).
    public var tailTime: Time
    /// Media time of the first / last visible frame (for a reversed clip the head is the later one).
    public var sourceHead: Time
    public var sourceTail: Time
    /// Slip applied so far (source start now minus at mouse down); zero = nothing moved yet.
    public var offset: Time

    public init(clip c: Clip, frameDuration fd: Time, startSource: Time) {
        clip = c.id
        headTime = c.start
        tailTime = max(c.start, c.timeline.end - fd)
        let lastStep = c.speed.scale(fd)
        if c.reversed {
            sourceHead = c.source.end - lastStep; sourceTail = c.source.start
        } else {
            sourceHead = c.source.start; sourceTail = c.source.end - lastStep
        }
        offset = c.source.start - startSource
    }

    /// "+12 f" / "-3 f" readout; whole frames.
    public func offsetLabel(frameDuration: Time) -> String {
        TimelineInteraction.frameText(offset, frameDuration)
    }
}
