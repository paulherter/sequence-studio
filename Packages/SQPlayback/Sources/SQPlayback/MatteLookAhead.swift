import Foundation
import SQCore
import SQMedia

/// Which source frames of a clip the next playback ticks show, for the Magic matte look-ahead
/// (`MagicMatteStore.prepare`): the coming timeline times are sent through the same evaluation a tick uses, so a
/// reversed clip, a clip speed, a speed ramp and reverse or fast playback all prepare the frames that are shown next,
/// not the neighbors of the shown frame in the file.
enum MatteLookAhead {
    /// The timeline times of the next `count` different frames after grid time `t` at playback `rate` (one tick per
    /// sequence frame: the clock moves `rate` frames per tick; a slow rate shows a frame several ticks long). Times
    /// before the sequence start are left out.
    static func times(after t: Time, frame fd: Time, rate: PlaybackRate, count: Int) -> [Time] {
        guard count > 0, !rate.isPaused else { return [] }
        let num = Int64(abs(Int(rate.num))), den = Int64(max(1, rate.den))
        var out: [Time] = []
        var last: Int64 = 0
        var k: Int64 = 1
        while out.count < count, k <= Int64(count) * den {
            let frames = k * num / den
            k += 1
            guard frames != last else { continue }
            last = frames
            let at = rate.isReverse ? t - fd * frames : t + fd * frames
            if at.isNegative { break }
            out.append(at)
        }
        return out
    }

    /// Per clip in `clips`: the source times its layers ask for at the coming timeline times (`times`), in playing
    /// order. `layers`: the tick's evaluation of the timeline at a time. A clip that ends before a time has none there.
    static func sourceTimes(after t: Time, frame fd: Time, rate: PlaybackRate, count: Int, clips: Set<Clip.ID>,
                            layers: (Time) -> [LayerRequest]) -> [Clip.ID: [Time]] {
        guard !clips.isEmpty else { return [:] }
        var out: [Clip.ID: [Time]] = [:]
        for at in times(after: t, frame: fd, rate: rate, count: count) {
            for r in layers(at) where clips.contains(r.clip) && !(out[r.clip]?.contains(r.sourceTime) ?? false) {
                out[r.clip, default: []].append(r.sourceTime)
            }
        }
        return out
    }

    /// The same answer for the clips of `requests` (the tick's layers at `t`) that show a Magic matte, without
    /// evaluating the timeline four more times per tick: each such layer's source time at a coming time comes from
    /// its clips' own time mappings (`LayerTimePath`). `layers` is asked only for a coming time one of them cannot
    /// answer (a clip edge is crossed, a transition), so a tick inside its clips evaluates the timeline once.
    static func sourceTimes(after t: Time, frame fd: Time, rate: PlaybackRate, count: Int, requests: [LayerRequest],
                            in timeline: Timeline, sequences: SequenceResolver,
                            layers: (Time) -> [LayerRequest]) -> [Clip.ID: [Time]] {
        let masked = requests.filter { r in r.effects.magicMattes.contains { !$0.mustCover } }
        guard !masked.isEmpty else { return [:] }
        let coming = times(after: t, frame: fd, rate: rate, count: count)
        guard !coming.isEmpty else { return [:] }
        let clips = Set(masked.map(\.clip))
        var paths: [(clip: Clip.ID, path: LayerTimePath)] = []
        for r in masked {
            guard let p = LayerTimePath(r, at: t, in: timeline, sequences: sequences) else { break }
            paths.append((r.clip, p))
        }
        let known = paths.count == masked.count
        var out: [Clip.ID: [Time]] = [:]
        var derived: [(Clip.ID, Time)] = []
        for at in coming {
            derived.removeAll(keepingCapacity: true)
            if known {
                for p in paths {
                    guard let s = p.path.sourceTime(at: at) else { break }
                    derived.append((p.clip, s))
                }
            }
            if !known || derived.count < paths.count {
                derived = layers(at).filter { clips.contains($0.clip) }.map { ($0.clip, $0.sourceTime) }
            }
            for (clip, s) in derived where !(out[clip]?.contains(s) ?? false) { out[clip, default: []].append(s) }
        }
        return out
    }

    /// The source frames (seconds, as the store keys them) that show the coming source times `times`, in playing
    /// order, each once and without the frame shown now (`shown`).
    static func frames(_ times: [Time], shown: Int, in index: SampleIndex) -> [Double] {
        guard index.count > 0 else { return [] }
        var seen: Set<Int> = [shown]
        var out: [Double] = []
        for t in times {
            let f = index.clampedFrame(at: t)
            guard seen.insert(f).inserted else { continue }
            let pts = index.entries[f].pts
            out.append(Double(pts.value) / Double(max(pts.timescale, 1)))
        }
        return out
    }
}
