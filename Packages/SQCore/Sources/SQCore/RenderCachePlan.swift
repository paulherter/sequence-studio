import Foundation

/// Preview render cache, model part 1 (the design notes "Preview render cache"): splits the visible video of a sequence
/// into segments at every clip edge and gives each a content key. The key covers what the picture depends on (clips
/// with times relative to the segment, effects, speed, transitions, nested content, media stamps, sequence format,
/// renderer id, working space) and nothing about the segment's place on the timeline, so a ripple edit keeps the key of
/// every later segment. Nothing here is stored in the project file.
public struct RenderCacheContext: Sendable {
    /// Changes whenever the renderer's output changes (shader or effect code revision).
    public var rendererID: String
    /// Working color space name.
    public var workingSpace: String
    /// Changes when the media file changes (size + modification date); a missing stamp is the empty string.
    public var mediaStamp: @Sendable (UUID) -> String
    public init(rendererID: String, workingSpace: String, mediaStamp: @escaping @Sendable (UUID) -> String = { _ in "" }) {
        self.rendererID = rendererID; self.workingSpace = workingSpace; self.mediaStamp = mediaStamp
    }
}

/// Two-lane FNV-1a: stable across launches (unlike `Hasher`), 128 bits, no crypto needed (keys are not secrets).
struct StableHash {
    private var a: UInt64 = 0xcbf29ce484222325
    private var b: UInt64 = 0x84222325cbf29ce4
    mutating func add(_ bytes: some Sequence<UInt8>) {
        for x in bytes {
            a = (a ^ UInt64(x)) &* 0x100000001b3
            b = ((b &+ UInt64(x) &+ 1) &* 0x100000001b3) ^ (a >> 7)
        }
    }
    mutating func add(_ s: String) { add(Array(s.utf8)); add([0xff]) }
    var hex: String {
        func h(_ v: UInt64) -> String { let s = String(v, radix: 16); return String(repeating: "0", count: 16 - s.count) + s }
        return h(a) + h(b)
    }
}

public struct RenderCacheSegment: Sendable, Hashable {
    public var range: TimeRange
    public var key: String
    /// Worth caching: effects, speed change, transition, nested sequence, generator, or two or more layers.
    public var isHeavy: Bool
}

public enum RenderCachePlan {
    static let maxNesting = 4
    private static let nullID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public static func segments(of timeline: Timeline, resolver: SequenceResolver? = nil,
                                context: RenderCacheContext) -> [RenderCacheSegment] {
        segments(of: timeline, resolver: resolver, context: context, depth: 0)
    }

    private static func segments(of timeline: Timeline, resolver: SequenceResolver?, context: RenderCacheContext,
                                 depth: Int) -> [RenderCacheSegment] {
        let tracks = timeline.tracks.filter { $0.kind == .video && $0.isVisible }
        var points = Set<Time>()
        for t in tracks { for c in t.clips { points.insert(c.timeline.start); points.insert(c.timeline.end) } }
        let sorted = points.sorted()
        var out: [RenderCacheSegment] = []
        for (lo, hi) in zip(sorted, sorted.dropFirst()) {
            let r = TimeRange(start: lo, duration: hi - lo)
            var layers = 0, heavy = false
            var h = StableHash()
            h.add("sq-render-cache-1"); h.add(context.rendererID); h.add(context.workingSpace)
            h.add(json(timeline.format)); h.add(json(r.duration))
            for t in tracks {
                let clips = t.clips.filter { $0.timeline.overlaps(r) }
                guard !clips.isEmpty else { h.add("-"); continue }
                layers += clips.count
                h.add("track")
                for c in clips {
                    var n = c
                    n.id = nullID; n.name = ""; n.link = nil; n.bundle = nil; n.label = nil
                    n.start = c.start - r.start
                    h.add(json(n)); h.add(context.mediaStamp(c.media))
                    if !c.effects.isEmpty || c.speed != .normal || c.sequence != nil || c.generator != nil { heavy = true }
                    if let s = c.sequence, depth < maxNesting, let inner = resolver?(s) {
                        h.add("nest")
                        for seg in segments(of: inner, resolver: resolver, context: context, depth: depth + 1) { h.add(seg.key) }
                    }
                }
                for tr in t.transitions {
                    let o = clips.firstIndex { $0.id == tr.outgoing }, i = clips.firstIndex { $0.id == tr.incoming }
                    guard o != nil || i != nil else { continue }
                    var n = tr
                    n.id = nullID; n.outgoing = nil; n.incoming = nil
                    h.add("tr\(o ?? -1),\(i ?? -1)"); h.add(json(n)); heavy = true
                    // The other side of the cut is not in this segment, but its handle frames are part of the picture.
                    for other in [tr.outgoing, tr.incoming] where other != nil && !clips.contains(where: { $0.id == other }) {
                        if var oc = t.clips.first(where: { $0.id == other }) {
                            oc.id = nullID; oc.name = ""; oc.link = nil; oc.bundle = nil; oc.label = nil
                            oc.start = oc.start - r.start
                            h.add("other"); h.add(json(oc)); h.add(context.mediaStamp(oc.media))
                        }
                    }
                }
            }
            out.append(RenderCacheSegment(range: r, key: h.hex, isHeavy: heavy || layers >= 2))
        }
        return out
    }

    private static func json(_ v: some Encodable) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
