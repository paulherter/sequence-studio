import Foundation

// Which tracked Magic mattes a render reads: per exported frame (the export warning counts frames without one, nested
// sequences included) and per project (the matte cache keeps what the project refers to and drops orphans).

/// One Magic matte a frame needs: the mask's matte cache key and the source time (s) of the frame it is drawn on.
public struct MagicMatteNeed: Sendable, Hashable {
    public var key: String
    public var pts: Double
    public init(key: String, pts: Double) { self.key = key; self.pts = pts }
}

extension Clip {
    /// Cache keys of the Magic masks a render draws: enabled, picked, and cutting the picture or feeding an effect.
    public var renderedMagicKeys: [String] {
        let inputs = Set(effects.filter { takesMaskInput($0) }.flatMap(\.maskInput))
        return masks.filter { m in
            m.enabled && m.source == .magic && !(m.magic?.points.isEmpty ?? true) && (m.usedByOpacity || inputs.contains(m.id))
        }.compactMap { $0.magic?.matteKey(media: media) }
    }
}

extension Timeline {
    static func seconds(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }

    /// Nesting deeper than this is not followed (guards against a cycle).
    static let magicNeedsMaxDepth = 8

    /// One entry per frame a render draws with a Magic mask: every frame of a clip that has one, and every frame of a nested
    /// clip whose inner sequence shows one at that frame (recursively). Each entry lists the mattes that frame reads.
    /// `sequences`: the nested sequences by id.
    public func magicMatteNeeds(sequences: [Timeline.ID: Timeline]) -> [[MagicMatteNeed]] {
        magicMatteNeeds(sequences: sequences, depth: 0)
    }

    func magicMatteNeeds(sequences: [Timeline.ID: Timeline], depth: Int) -> [[MagicMatteNeed]] {
        var out: [[MagicMatteNeed]] = []
        for track in tracks where track.kind == .video {
            for c in track.clips {
                if let id = c.sequence {
                    guard depth < Self.magicNeedsMaxDepth, let inner = sequences[id].map(c.angleView(of:)),
                          inner.showsMagic(sequences: sequences, depth: depth + 1) else { continue }
                    var t = Time.zero
                    while t < c.duration {
                        let it = c.innerTime(atLocal: t, innerFrameDuration: inner.frameDuration)
                        let n = inner.magicMatteNeeds(at: it, sequences: sequences, depth: depth + 1)
                        if !n.isEmpty { out.append(n) }
                        t = t + frameDuration
                    }
                    continue
                }
                let keys = c.renderedMagicKeys
                guard !keys.isEmpty else { continue }
                var t = Time.zero
                while t < c.duration {
                    let pts = Self.seconds(c.shownSourceTime(atLocal: t, frameDuration: frameDuration))
                    out.append(keys.map { MagicMatteNeed(key: $0, pts: pts) })
                    t = t + frameDuration
                }
            }
        }
        return out
    }

    /// The mattes needed at this timeline's time `t`: every video clip covering `t`, nested clips followed.
    func magicMatteNeeds(at t: Time, sequences: [Timeline.ID: Timeline], depth: Int) -> [MagicMatteNeed] {
        var out: [MagicMatteNeed] = []
        for track in tracks where track.kind == .video {
            for c in track.clips where c.start <= t && t < c.start + c.duration {
                let local = t - c.start
                if let id = c.sequence {
                    guard depth < Self.magicNeedsMaxDepth, let inner = sequences[id].map(c.angleView(of:)) else { continue }
                    out += inner.magicMatteNeeds(at: c.innerTime(atLocal: local, innerFrameDuration: inner.frameDuration),
                                                 sequences: sequences, depth: depth + 1)
                    continue
                }
                let keys = c.renderedMagicKeys
                guard !keys.isEmpty else { continue }
                let pts = Self.seconds(c.shownSourceTime(atLocal: local, frameDuration: frameDuration))
                out += keys.map { MagicMatteNeed(key: $0, pts: pts) }
            }
        }
        return out
    }

    /// Some clip here (or in a sequence nested here) draws a Magic mask.
    func showsMagic(sequences: [Timeline.ID: Timeline], depth: Int) -> Bool {
        tracks.contains { track in
            track.kind == .video && track.clips.contains { c in
                if let id = c.sequence {
                    return depth < Self.magicNeedsMaxDepth && (sequences[id].map(c.angleView(of:))?.showsMagic(sequences: sequences, depth: depth + 1) ?? false)
                }
                return !c.renderedMagicKeys.isEmpty
            }
        }
    }
}

extension Project {
    /// Matte cache keys of every picked Magic mask in the project (enabled or not: the matte is kept while the pick exists).
    /// A Face / Skin mask made by Anonymize needs two: the followed person and the narrowed matte. What is not listed is
    /// removed when the project closes saved, which is also how the mattes of a deleted mask go.
    public var magicMatteCacheKeys: Set<String> {
        var out = Set<String>()
        for tl in timelines {
            for track in tl.tracks {
                for c in track.clips {
                    for m in c.masks where m.source == .magic {
                        if let sel = m.magic, !sel.points.isEmpty { out.formUnion(sel.matteKeys(media: c.media)) }
                    }
                }
            }
        }
        return out
    }
}
