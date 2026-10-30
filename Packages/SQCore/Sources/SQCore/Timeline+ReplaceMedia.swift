import Foundation

/// The media a Replace edit puts into a clip: what SQCore needs to know about it (the probe result lives elsewhere).
public struct ReplacementMedia: Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var duration: Time
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var isStill: Bool

    public init(id: UUID, name: String, duration: Time, hasVideo: Bool, hasAudio: Bool, isStill: Bool = false) {
        self.id = id; self.name = name; self.duration = duration
        self.hasVideo = hasVideo; self.hasAudio = hasAudio; self.isStill = isStill
    }
}

/// Where the new media starts playing in a Replace edit.
public enum ReplaceAlignment: Sendable, Hashable {
    /// The clip's first frame shows `sourceIn` of the new media.
    case clipStart(sourceIn: Time)
    /// The frame of the new media at `mediaTime` (its own playhead) shows at `timelineTime` (Shift+Option: match frame).
    case matchFrame(mediaTime: Time, timelineTime: Time)
}

extension Timeline {
    /// Replace edit (Option-drop of a Project item onto a clip): the clip plays `media` instead, keeping its position,
    /// timeline length, track, link, speed, effects and keys. A linked partner that played the same media follows when the
    /// new media has that stream. Refused (nothing changes) when the new media is too short for the played range
    /// (`insufficientMedia`), lacks the clip's stream (`wrongTrackKind`), or the clip is a still, nest, generator, held frame
    /// or speed-remapped clip (`speedUnsupported`). `trackLocked` for a locked track.
    public mutating func replaceMedia(of clipID: Clip.ID, with media: ReplacementMedia, alignment: ReplaceAlignment) throws {
        guard let ti = tracks.firstIndex(where: { $0.clip(clipID) != nil }), let old = tracks[ti].clip(clipID) else {
            throw EditError.clipNotFound
        }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        guard !old.isNested, !old.isGenerator, !old.isStill, old.holdFrame == nil, old.speedKeys == nil, !media.isStill else {
            throw EditError.speedUnsupported
        }
        guard old.kind == .video ? media.hasVideo : media.hasAudio else { throw EditError.wrongTrackKind }

        let newStart: Time
        switch alignment {
        case .clipStart(let sourceIn): newStart = sourceIn
        case .matchFrame(let mediaTime, let timelineTime):
            let into = old.speed.scale(timelineTime - old.start)       // source time between the clip's first frame and the match
            newStart = old.reversed ? mediaTime + into - old.source.duration : mediaTime - into
        }
        func fits(_ start: Time, _ length: Time) -> Bool { start >= .zero && start + length <= media.duration }
        guard fits(newStart, old.source.duration) else { throw EditError.insufficientMedia }

        var work = self
        func swap(_ c: Clip, start: Time) -> Clip {
            var n = c
            n.media = media.id; n.name = media.name; n.mediaDuration = media.duration
            n.source.start = start
            n.footageColor = ClipFootageColor()        // the old footage's interpretation does not belong to the new media
            n.markers = nil                            // clip markers are in source time of the old media
            return n
        }
        work.tracks[ti].replace(swap(old, start: newStart))

        if let link = old.link {
            for pi in work.tracks.indices where pi != ti {
                guard let p = work.tracks[pi].clips.first(where: { $0.link == link && $0.kind != old.kind && $0.media == old.media }),
                      p.kind == .video ? media.hasVideo : media.hasAudio else { continue }
                guard !work.tracks[pi].isLocked else { throw EditError.trackLocked }
                let pStart = p.source.start - old.source.start + newStart
                guard fits(pStart, p.source.duration) else { throw EditError.insufficientMedia }
                work.tracks[pi].replace(swap(p, start: pStart))
            }
        }
        self = work
    }
}
