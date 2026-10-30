import Foundation
import SQCore

/// Export decode-ahead across cuts: walks the output timeline `leadFrames` ahead of the render position, one frame at a
/// time, and reports every media layer that appears there (a clip start, a transition's incoming clip, a nested clip),
/// with the source time of its first frame. Layers already drawn at the first scanned frame are not reported (the render
/// asks for them itself). Export moves forward; after a jump the scan restarts at the new position.
struct ClipPrefetchScanner: Sendable {
    struct Hint: Sendable, Hashable {
        var media: UUID
        var sourceTime: Time
    }

    private struct Key: Hashable {
        var clip: UUID
        var media: UUID
    }

    let start: Time
    let frameDuration: Time
    let frameCount: Int
    let leadFrames: Int
    /// Last scanned time and the media layers drawn there.
    private var scanned: Time?
    private var previous: Set<Key> = []

    init(start: Time, frameDuration: Time, frameCount: Int, leadFrames: Int) {
        self.start = start; self.frameDuration = frameDuration; self.frameCount = frameCount; self.leadFrames = max(0, leadFrames)
    }

    /// The layers that first appear in the frames after the last scanned one, up to `t + leadFrames` (never past the
    /// last frame). `layers` evaluates the timeline at a time.
    mutating func advance(to t: Time, layers: (Time) -> [LayerRequest]) -> [Hint] {
        guard frameCount > 0, frameDuration > .zero else { return [] }
        let last = start + frameDuration * Int64(frameCount - 1)
        func keys(_ ls: [LayerRequest]) -> Set<Key> { Set(ls.filter { $0.generator == nil }.map { Key(clip: $0.clip, media: $0.media) }) }
        if scanned.map({ t >= $0 }) ?? true {
            scanned = t
            previous = keys(layers(t))
        }
        let horizon = min(t + frameDuration * Int64(leadFrames), last)
        var out: [Hint] = [], seen = Set<Hint>()
        while let s = scanned, s + frameDuration <= horizon {
            let at = s + frameDuration
            scanned = at
            let ls = layers(at).filter { $0.generator == nil }
            for l in ls where !previous.contains(Key(clip: l.clip, media: l.media)) {
                let h = Hint(media: l.media, sourceTime: l.sourceTime)
                if seen.insert(h).inserted { out.append(h) }
            }
            previous = keys(ls)
        }
        return out
    }
}
