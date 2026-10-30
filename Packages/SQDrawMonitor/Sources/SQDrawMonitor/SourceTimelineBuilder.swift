import SQCore

/// The one-clip timeline the Source monitor plays for a media item, and the displayed shape it was built for. The
/// monitor builds it again (without stopping) when the shape changes, for example after a pixel aspect change.
public enum SourceTimelineBuilder {
    public struct Built: Sendable {
        public var timeline: Timeline
        public var format: SequenceFormat
        public var total: Time
        public var still: Bool
    }

    /// Displayed size [width, height] of the item's picture; empty for media without one.
    public static func shape(of ref: MediaRef) -> [Int] {
        guard let v = ref.info?.video else { return [] }
        return [v.displayWidth, v.displayHeight]
    }

    /// nil without a readable duration.
    public static func build(_ ref: MediaRef) -> Built? {
        let still = ref.info?.isStill == true
        guard let total = still ? Time(5, 1) : (ref.info?.duration ?? ref.duration) else { return nil }
        let video = ref.info?.video
        let fd = still ? Time(1, 30) : (video?.nominalFrameDuration ?? Time(1, 30))
        let format = SequenceFormat(width: video?.displayWidth ?? 1920, height: video?.displayHeight ?? 1080,
                                    frameDuration: fd, audioSampleRate: ref.info?.audio?.sampleRate ?? 48_000).sanitized()
        let tl = Timeline.sourceTimeline(media: ref, format: format, hasVideo: video != nil || ref.info == nil,
                                         hasAudio: ref.info?.audio != nil, duration: total, isStill: still)
        return Built(timeline: tl, format: format, total: total, still: still)
    }

    /// The playhead after a rebuild: snapped to the (possibly new) frame rate and kept inside the new length.
    public static func clampedPosition(_ position: Time, total: Time, frameDuration fd: Time) -> Time {
        min(position.snapped(to: fd), max(.zero, total - fd))
    }

    /// The play In to Out range after a rebuild: cut at the new end; nil when nothing of it is left.
    public static func clampedRange(_ range: TimeRange?, total: Time) -> TimeRange? {
        guard let range else { return nil }
        let end = min(range.end, total)
        guard range.start < end else { return nil }
        return TimeRange(start: range.start, end: end)
    }

    /// Whether a monitor showing `loaded` must be rebuilt for `ref`: only media with a picture whose shape moved.
    public static func needsReshape(_ ref: MediaRef, loaded: [Int]) -> Bool {
        ref.info?.video != nil && loaded != shape(of: ref)
    }
}
