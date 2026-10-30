import Foundation

/// Audio sync with drift: two recordings of one event whose clocks run slightly apart (camera against a recorder).
/// Pure Swift on loudness envelopes (see `AnglesAudioSync`): the other recording is cut into chunks, each chunk is
/// matched against the reference near the global lag, and a confidence-weighted line through (position, lag) gives the
/// start offset and the drift ratio. `Timeline.syncAudio` applies the result as a move plus a retime in one edit.
public enum AudioDriftFit {
    public enum Method: Sendable, Equatable { case sound, timecode, captureDate }

    public struct Fit: Sendable, Equatable {
        /// Where the other file's time 0 lies on the reference file's clock (positive: other started later).
        public var offset: Time
        /// Growth of the lag per second of the other file: `lag(t) = offset + driftRatio * t`. 0 = no drift found.
        public var driftRatio: Double
        /// Mean correlation of the chunks that took part, 0...1 (1 for timecode).
        public var confidence: Double
        public var chunksUsed: Int
        public var chunkCount: Int
        public var method: Method

        public init(offset: Time, driftRatio: Double, confidence: Double, chunksUsed: Int, chunkCount: Int, method: Method) {
            self.offset = offset; self.driftRatio = driftRatio; self.confidence = confidence
            self.chunksUsed = chunksUsed; self.chunkCount = chunkCount; self.method = method
        }

        /// Speed that lines the other recording up with the reference over its whole length; nil when the drift is
        /// below `minimumDrift` (a retime would change nothing audible).
        public var correctingSpeed: ClipSpeed? {
            guard abs(driftRatio) >= AudioDriftFit.minimumDrift, driftRatio > -0.5 else { return nil }
            // Source time p lands at p * (1 + drift) on the reference clock: play it at 1 / (1 + drift).
            let scale: Int64 = 1_000_000
            let num = Int64((Double(scale) / (1 + driftRatio)).rounded())
            let s = ClipSpeed(num: num, den: scale)
            return s == .normal ? nil : s
        }
    }

    /// Below this ratio (10 ppm, 36 ms per hour) a drift is not corrected.
    public static let minimumDrift = 1e-5
    /// Chunks shorter than this many seconds correlate too loosely to place; fewer chunks are used instead.
    public static let minimumChunkSeconds = 10

    /// nil when the recordings do not match as a whole (silence, too short, below `AnglesAudioSync.weakConfidence`,
    /// or the offset lies outside `searchWindow`, an optional limit on |offset| in seconds).
    /// With fewer than 3 usable chunks the drift is 0 and only the offset is reported.
    public static func fit(reference: [Float], other: [Float], rate: Int, chunkCount: Int = 8,
                           searchWindow: Double? = nil) -> Fit? {
        // The whole-file match is only a starting lag: with drift its correlation is smeared and may be weak, so the
        // confidence gate applies to the chunks (or to this match when no drift can be fitted).
        guard rate > 0, let global = AnglesAudioSync.match(reference: reference, other: other) else { return nil }
        if let w = searchWindow, abs(Double(global.lag)) / Double(rate) > w { return nil }
        let wholeOffset = Time(Int64(global.lag), Int64(rate))
        let single = Fit(offset: wholeOffset, driftRatio: 0, confidence: global.confidence, chunksUsed: 1, chunkCount: 1, method: .sound)

        let weak = global.confidence < AnglesAudioSync.weakConfidence
        func fallback() -> Fit? { weak ? nil : single }
        let chunks = min(chunkCount, other.count / (minimumChunkSeconds * rate))
        guard chunks >= 3 else { return fallback() }
        let length = other.count / chunks
        let window = max(3 * rate, other.count / 50)
        var xs: [Double] = [], ys: [Double] = [], ws: [Double] = []
        for k in 0..<chunks {
            let from = k * length, to = k == chunks - 1 ? other.count : from + length
            let base = max(0, from + global.lag - window)
            let top = min(reference.count, to + global.lag + window)
            guard top - base >= (to - from) / 2 else { continue }
            let piece = Array(other[from..<to])
            guard let m = AnglesAudioSync.match(reference: Array(reference[base..<top]), other: piece,
                                                minOverlap: (to - from) / 2),
                  m.confidence >= AnglesAudioSync.weakConfidence else { continue }
            // piece[i] lines up with reference[base + i + m.lag]; other[from + i] with reference[from + i + lag].
            xs.append(Double(from + to) / 2); ys.append(Double(m.lag + base - from)); ws.append(m.confidence)
        }
        guard xs.count >= 3, var line = regression(xs, ys, ws) else { return fallback() }
        // One pass of outlier rejection: chunks that hit a repeated phrase or a noisy stretch.
        let residuals = xs.indices.map { abs(ys[$0] - (line.intercept + line.slope * xs[$0])) }
        let limit = max(3, 3 * residuals.sorted()[residuals.count / 2])
        let keep = residuals.indices.filter { residuals[$0] <= limit }
        guard keep.count >= 3 else { return fallback() }
        if keep.count < xs.count, let again = regression(keep.map { xs[$0] }, keep.map { ys[$0] }, keep.map { ws[$0] }) { line = again }
        let confidence = keep.map { ws[$0] }.reduce(0, +) / Double(keep.count)
        let offset = Time(Int64(line.intercept.rounded()), Int64(rate))
        return Fit(offset: offset, driftRatio: line.slope, confidence: min(confidence, 1), chunksUsed: keep.count,
                   chunkCount: chunks, method: .sound)
    }

    /// Timecode mode: both files carry a start time of day (timecode, or the capture date as the caller's fallback);
    /// the offset is the difference and nothing drifts.
    public static func timecode(reference: Time, other: Time) -> Fit {
        Fit(offset: other - reference, driftRatio: 0, confidence: 1, chunksUsed: 1, chunkCount: 1, method: .timecode)
    }

    /// Last resort: whole-second capture dates of the two files. Accurate only to about a second, so callers warn.
    public static func captureDate(reference: Time, other: Time) -> Fit {
        Fit(offset: other - reference, driftRatio: 0, confidence: 1, chunksUsed: 1, chunkCount: 1, method: .captureDate)
    }

    private static func regression(_ x: [Double], _ y: [Double], _ w: [Double]) -> (intercept: Double, slope: Double)? {
        let sw = w.reduce(0, +)
        guard sw > 0 else { return nil }
        let mx = zip(x, w).reduce(0) { $0 + $1.0 * $1.1 } / sw
        let my = zip(y, w).reduce(0) { $0 + $1.0 * $1.1 } / sw
        var sxx = 0.0, sxy = 0.0
        for i in x.indices { sxx += w[i] * (x[i] - mx) * (x[i] - mx); sxy += w[i] * (x[i] - mx) * (y[i] - my) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return (my - slope * mx, slope)
    }
}

extension Timeline {
    /// Lines the clip `id` (and its linked partners) up with `reference` by a sync fit: the group moves so the shared
    /// event lands at the same time, and with `retime` the drift is corrected by a constant speed. One edit; nothing
    /// changes when it throws. `fit` relates the two clips' files (`AudioDriftFit.fit(reference:other:)`).
    /// shortcut: the reference clip must play at 100 % and the position is snapped to whole frames (up to half a frame
    /// off), upgrade when audio-only sub-frame placement is wanted.
    public mutating func syncAudio(_ id: Clip.ID, to reference: Clip.ID, fit: AudioDriftFit.Fit, retime: Bool = true) throws {
        guard let ref = find(reference)?.clip else { throw EditError.clipNotFound }
        guard ref.speed == .normal, ref.speedKeys == nil, !ref.reversed else { throw EditError.speedUnsupported }
        guard let target = find(id)?.clip, id != reference else { throw EditError.clipNotFound }
        // A reversed or remapped clip has no single source-start-to-position relation (and no constant drift speed).
        guard target.speedKeys == nil, !target.reversed else { throw EditError.speedUnsupported }
        let group = try linkedGroup(id)
        // The reference never moves with the clip: syncing a clip to its own linked partner is meaningless.
        if group.contains(where: { $0.clip.id == reference }) { throw EditError.collision }
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }

        let speed = retime && fit.method == .sound ? fit.correctingSpeed : nil
        let drift = speed == nil ? 0 : fit.driftRatio
        // Source frame p of the other file lands on reference media time p * (1 + drift) + offset. A retime keeps the
        // source start, so the position is known before the clip is touched.
        let p = target.source.start
        let extra = Time(Int64((Double(p.value) / Double(p.timescale) * drift * 1_000_000).rounded()), 1_000_000)
        let at = ref.start + (p + extra + fit.offset - ref.source.start)
        let delta = at.snapped(to: frameDuration) - target.start

        // Move first, then retime: the retime must see the clip where it ends up. Nothing at the destination may be
        // cut or deleted: the range is checked at the old and at the retimed length.
        var work = self
        if delta != .zero {
            let ids = Set(group.map(\.clip.id))
            for m in group {
                var length = m.clip.duration
                if let speed { length = max(length, speed.unscale(m.clip.retimeSpan).ceiled(to: frameDuration)) }
                let range = TimeRange(start: m.clip.start + delta, duration: length)
                if range.start < .zero { throw EditError.collision }
                if tracks[m.track].clips.contains(where: { !ids.contains($0.id) && $0.timeline.overlaps(range) }) {
                    throw EditError.collision
                }
            }
            for m in group {
                var moved = m.clip
                moved.start = moved.start + delta
                work.tracks[m.track].replace(moved)
            }
            guard work.tracks.allSatisfy({ $0.isConsistent }) else { throw EditError.collision }
        } else if let speed {
            for m in group {
                let range = TimeRange(start: m.clip.start, duration: speed.unscale(m.clip.retimeSpan).ceiled(to: frameDuration))
                let ids = Set(group.map(\.clip.id))
                if tracks[m.track].clips.contains(where: { !ids.contains($0.id) && $0.timeline.overlaps(range) }) {
                    throw EditError.collision
                }
            }
        }
        if let speed { try work.setSpeed(id, to: speed) }
        self = work
    }
}
