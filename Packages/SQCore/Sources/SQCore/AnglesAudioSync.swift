import Foundation

/// Sync by audio for Create Angles Clip: finds how far one recording's loudness envelope is shifted against another's.
/// Pure Swift on envelopes (one value per time step, same step for both), no audio decoding here: the caller builds the
/// envelopes (SQMedia: `WaveformData.envelope(rate:)`).
///
/// Method: mean-removed, normalized cross-correlation. The search runs on envelopes thinned to at most `coarseLimit`
/// values (every lag with enough overlap), then the best lag is refined level by level back up to the full rate.
public enum AnglesAudioSync {
    public struct Match: Sendable, Equatable {
        /// `other[i]` lines up with `reference[i + lag]`: positive = `other` started later than `reference`.
        public var lag: Int
        /// Correlation at that lag, 0...1 (1 = identical shape).
        public var confidence: Double
    }

    /// Below this confidence the recordings most likely do not share sound.
    public static let weakConfidence = 0.3

    /// nil when an envelope is too short, silent, or nothing correlates positively.
    /// `minOverlap`: values both envelopes must share at a lag (default: a quarter of the shorter one).
    public static func match(reference: [Float], other: [Float], minOverlap: Int? = nil, coarseLimit: Int = 4096) -> Match? {
        guard reference.count >= 16, other.count >= 16 else { return nil }
        let a0 = centered(reference), b0 = centered(other)
        var factor = 1
        while max(a0.count, b0.count) / factor > max(coarseLimit, 64) { factor *= 2 }
        let need = max(minOverlap ?? min(a0.count, b0.count) / 4, 8)

        // Coarse: every lag with enough overlap.
        let a = thinned(a0, by: factor), b = thinned(b0, by: factor)
        let needCoarse = max(need / factor, 4)
        var best = -Double.infinity, bestLag = 0
        guard a.count >= needCoarse, b.count >= needCoarse else { return nil }
        for lag in (needCoarse - b.count)...(a.count - needCoarse) {
            let s = score(a, b, lag: lag, minOverlap: needCoarse)
            if s > best { best = s; bestLag = lag }
        }
        guard best > 0 else { return nil }

        // Refine: at each finer level the lag is known to about one coarse step.
        var f = factor
        while f > 1 {
            f /= 2
            let x = f == 1 ? a0 : thinned(a0, by: f), y = f == 1 ? b0 : thinned(b0, by: f)
            let center = bestLag * 2
            best = -Double.infinity
            for lag in (center - 2)...(center + 2) {
                let s = score(x, y, lag: lag, minOverlap: max(need / f, 4))
                if s > best { best = s; bestLag = lag }
            }
        }
        guard best > 0, best.isFinite else { return nil }
        return Match(lag: bestLag, confidence: min(best, 1))
    }

    /// The lag as time for envelopes of `rate` values per second.
    public static func time(lag: Int, rate: Int) -> Time { Time(Int64(lag), Int64(max(rate, 1))) }

    /// What the sound sync made of one angle.
    public enum Outcome: Sendable, Equatable {
        case reference
        case synced(confidence: Double)
        /// Not placed by sound; `confidence` is the best correlation found, nil when nothing correlated (silence, too short).
        case notSynced(confidence: Double?)
    }

    public struct Report<ID: Hashable>: Sendable where ID: Sendable {
        public var outcomes: [ID: Outcome]
        /// Angles that did not sync, in input order.
        public var failed: [ID]
        /// File origin per angle that synced (the reference at zero).
        public var origins: [ID: Time]
    }

    /// The file origins a sound sync found, with a verdict per angle. `envelopes`: one per angle whose sound could be
    /// read, in angle order; the first is the reference (origin 0). An angle whose match is missing or below
    /// `weakConfidence` gets no origin (it is lined up by its In point, see `AnglesOffsets.starts`), never a silent
    /// guess. Fewer than two envelopes: no origin at all.
    public static func report<ID: Hashable & Sendable>(envelopes: [(id: ID, envelope: [Float])], rate: Int) -> Report<ID> {
        guard let reference = envelopes.first, envelopes.count >= 2 else { return Report(outcomes: [:], failed: [], origins: [:]) }
        var origins: [ID: Time] = [reference.id: .zero]
        var outcomes: [ID: Outcome] = [reference.id: .reference]
        var failed: [ID] = []
        for e in envelopes.dropFirst() where outcomes[e.id] == nil {
            let m = match(reference: reference.envelope, other: e.envelope)
            if let m, m.confidence >= weakConfidence {
                origins[e.id] = time(lag: m.lag, rate: rate)
                outcomes[e.id] = .synced(confidence: m.confidence)
            } else {
                outcomes[e.id] = .notSynced(confidence: m?.confidence)
                failed.append(e.id)
            }
        }
        return Report(outcomes: outcomes, failed: failed, origins: origins)
    }

    /// `report` reduced to the origins and the count of angles that did not sync.
    public static func origins<ID: Hashable & Sendable>(envelopes: [(id: ID, envelope: [Float])], rate: Int) -> (origins: [ID: Time], unmatched: Int) {
        let r = report(envelopes: envelopes, rate: rate)
        return (r.origins, r.failed.count)
    }

    /// Status text for a sync by sound; nil when there is nothing to say.
    public static func note(failed: [(name: String, confidence: Double?)], synced: [Double], silent: Int, unreadable: Int) -> String? {
        func pct(_ c: Double) -> Int { Int((c * 100).rounded()) }
        var problems: [String] = failed.map { f in
            f.confidence.map { "\(f.name) (confidence \(pct($0)) %)" } ?? "\(f.name) (no match)"
        }
        if unreadable > 0 { problems.append(unreadable == 1 ? "1 file whose sound could not be read" : "\(unreadable) files whose sound could not be read") }
        var parts: [String] = []
        if !problems.isEmpty { parts.append("Could not sync by sound: " + problems.joined(separator: ", ") + ".") }
        if silent > 0 { parts.append("\(silent) without sound.") }
        if !problems.isEmpty || silent > 0 { parts.append("Those are lined up by In point.") }
        if let weakest = synced.min() { parts.append("Synced \(synced.count) by sound, weakest \(pct(weakest)) %.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func centered(_ v: [Float]) -> [Double] {
        let mean = v.reduce(0.0) { $0 + Double($1) } / Double(v.count)
        return v.map { Double($0) - mean }
    }

    private static func thinned(_ v: [Double], by f: Int) -> [Double] {
        guard f > 1 else { return v }
        var out: [Double] = []
        out.reserveCapacity(v.count / f + 1)
        var i = 0
        while i < v.count {
            let end = min(i + f, v.count)
            var sum = 0.0
            for k in i..<end { sum += v[k] }
            out.append(sum / Double(end - i))
            i = end
        }
        return out
    }

    /// Normalized correlation of `b[i]` against `a[i + lag]` over their overlap; -inf with too little overlap or silence.
    private static func score(_ a: [Double], _ b: [Double], lag: Int, minOverlap: Int) -> Double {
        let from = max(0, -lag), to = min(b.count, a.count - lag)
        guard to - from >= minOverlap else { return -.infinity }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var dot = 0.0, ea = 0.0, eb = 0.0
                for i in from..<to {
                    let x = pa[i + lag], y = pb[i]
                    dot += x * y; ea += x * x; eb += y * y
                }
                let norm = (ea * eb).squareRoot()
                return norm > 1e-12 ? dot / norm : -.infinity
            }
        }
    }
}
