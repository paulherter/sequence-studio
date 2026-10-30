import Foundation
import SQCore

// Anonymize search across a clip: people who enter later are found by looking at several frames, and the sightings of the
// same person on neighboring frames are linked into one entry (so a walking person is listed once, not once per frame).

/// One person to follow: where and when they are picked.
public struct AnonymizeSighting: Sendable, Hashable {
    public var person: AnonymizePerson
    /// Source seconds of the frame they are picked on.
    public var pts: Double
    /// Source seconds of the first sampled frame that shows them.
    public var firstSeen: Double
    public init(person: AnonymizePerson, pts: Double, firstSeen: Double) {
        self.person = person; self.pts = pts; self.firstSeen = firstSeen
    }
}

public enum AnonymizeSearch {
    /// Frames looked at: the anchor and evenly spaced frames across `first...last` at about `interval` seconds, at most
    /// `maxCount` in total (the spacing widens for a long clip). Ascending, no duplicates.
    public static func sampleTimes(first: Double, last: Double, anchor: Double, interval: Double = 0.5, maxCount: Int = 24) -> [Double] {
        let lo = min(first, last), hi = max(first, last)
        let a = min(max(anchor, lo), hi)
        guard hi - lo > 1e-6, maxCount > 1, interval > 0 else { return [a] }
        let steps = min(max(Int(((hi - lo) / interval).rounded(.up)), 1), maxCount - 1)
        var times = (0...steps).map { lo + (hi - lo) * Double($0) / Double(steps) }
        // The anchor replaces the nearest even sample so it is always one of the frames.
        if let i = times.indices.min(by: { abs(times[$0] - a) < abs(times[$1] - a) }) { times[i] = a }
        return Array(Set(times)).sorted()
    }

    /// Links the people of consecutive sampled frames: a person whose box center is within `reach` (frame fractions) of an
    /// open chain's last sighting continues it. One sighting per chain: the frame at `anchor` when they are on it, else
    /// the largest box. Ordered by first appearance, then left to right.
    public static func link(_ samples: [(pts: Double, people: [AnonymizePerson])], anchor: Double, reach: Double = 0.2) -> [AnonymizeSighting] {
        var chains: [[(pts: Double, person: AnonymizePerson)]] = []
        var open: [Int] = []                                    // chains seen on the previous sample
        for sample in samples.sorted(by: { $0.pts < $1.pts }) {
            var free = open
            var next: [Int] = []
            for p in sample.people.sorted(by: { $0.box.center.x < $1.box.center.x }) {
                let c = p.box.center
                let best = free.min { distance(chains[$0].last!.person.box.center, c) < distance(chains[$1].last!.person.box.center, c) }
                if let b = best, distance(chains[b].last!.person.box.center, c) <= reach {
                    chains[b].append((sample.pts, p))
                    free.removeAll { $0 == b }
                    next.append(b)
                } else {
                    chains.append([(sample.pts, p)])
                    next.append(chains.count - 1)
                }
            }
            open = next
        }
        return chains.map { chain in
            let atAnchor = chain.first { abs($0.pts - anchor) < 1e-6 }
            let pick = atAnchor ?? chain.max { $0.person.box.width * $0.person.box.height < $1.person.box.width * $1.person.box.height }!
            return AnonymizeSighting(person: pick.person, pts: pick.pts, firstSeen: chain[0].pts)
        }.sorted { ($0.firstSeen, $0.person.box.center.x) < ($1.firstSeen, $1.person.box.center.x) }
    }

    private static func distance(_ a: Vec2, _ b: Vec2) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }
}

#if canImport(Vision)
extension Anonymizer {
    /// Everyone who shows up on the sampled frames of the clip (`AnonymizeSearch.sampleTimes`), linked into one entry per
    /// person. nil = no frame could be read at all. `progress` 0...1 over the frames.
    public func findEveryone(first: Double, last: Double, anchor: Double, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [AnonymizeSighting]? {
        let times = AnonymizeSearch.sampleTimes(first: first, last: last, anchor: anchor)
        var samples: [(pts: Double, people: [AnonymizePerson])] = []
        for (i, t) in times.enumerated() {
            try Task.checkCancellation()
            if let f = try await findPeople(at: t) { samples.append((f.pts, f.people)) }
            progress?(Double(i + 1) / Double(times.count))
        }
        guard let nearest = samples.min(by: { abs($0.pts - anchor) < abs($1.pts - anchor) }) else { return nil }
        return AnonymizeSearch.link(samples, anchor: nearest.pts)
    }
}
#endif
