import Foundation
import SQCore

/// Loop, Convert to Keys and Wiggle on the tracks that hold selected keys (undoable, one commit each).
extension EffectControlsModel {
    /// Repeats the key pattern of every track with a selected key `cycles` more times (Loop).
    @discardableResult
    public func loopSelectedTracks(cycles: Int) -> Bool {
        editSelectedTracks(name: "Loop Keyframes") { track, _ in
            switch track {
            case .scalar(var t): t.loop(cycles: cycles); track = .scalar(t)
            case .vector(var t): t.loop(cycles: cycles); track = .vector(t)
            case .color(var t): t.loop(cycles: cycles); track = .color(t)
            case .path(var t): t.loop(cycles: cycles); track = .path(t)
            }
            return true
        }
    }

    /// Replaces the keys between the first and last selected key of each track by linear keys sampled from the
    /// curve (Convert to Keys). Needs two different selected key times on a track.
    @discardableResult
    public func bakeSelectedKeys(samplesPerSecond: Int) -> Bool {
        editSelectedTracks(name: "Convert to Keys") { track, r in
            switch track {
            case .scalar(var t):
                guard t.bakeSamples(from: r.lowerBound, to: r.upperBound, samplesPerSecond: samplesPerSecond) else { return false }
                track = .scalar(t)
            case .vector(var t):
                guard t.bakeSamples(from: r.lowerBound, to: r.upperBound, samplesPerSecond: samplesPerSecond) else { return false }
                track = .vector(t)
            case .color(var t):
                guard t.bakeSamples(from: r.lowerBound, to: r.upperBound, samplesPerSecond: samplesPerSecond) else { return false }
                track = .color(t)
            case .path(var t):
                guard t.bakeSamples(from: r.lowerBound, to: r.upperBound, samplesPerSecond: samplesPerSecond) else { return false }
                track = .path(t)
            }
            return true
        }
    }

    /// Wiggle between the first and last selected key of every number track (colors, vectors and paths are left alone).
    @discardableResult
    public func wiggleSelectedKeys(perSecond: Int, amount: Double, seed: UInt64) -> Bool {
        editSelectedTracks(name: "Wiggle Keyframes") { track, r in
            guard case .scalar(var t) = track,
                  t.wiggle(from: r.lowerBound, to: r.upperBound, perSecond: perSecond, amount: amount, seed: seed) else { return false }
            track = .scalar(t)
            return true
        }
    }

    /// True when a selected key sits on a number track (the only kind Wiggle applies to).
    public var hasSelectedScalarKey: Bool {
        guard let c = workingClip ?? clip else { return false }
        let tracks = KeyframeSummary(tracks: Self.tracks(of: c)).tracks
        return selection.contains {
            if case .scalar? = tracks[$0.property] { return true }
            return false
        }
    }

    private func editSelectedTracks(name: String, _ edit: (inout PropertyTrack, ClosedRange<Time>) -> Bool) -> Bool {
        guard let c = workingClip ?? clip, !selection.isEmpty else { return false }
        var s = KeyframeSummary(tracks: Self.tracks(of: c))
        var changed = false
        for (p, t) in s.tracks {
            let ids = Set(selection.filter { $0.property == p }.map(\.keyID))
            guard !ids.isEmpty else { continue }
            let times = t.times.filter { ids.contains($0.id) }.map(\.time)
            guard let lo = times.min(), let hi = times.max() else { continue }
            var track = t
            if edit(&track, lo...hi) { s.tracks[p] = track; changed = true }
        }
        guard changed else { return false }
        var out = c
        write(s.tracks, into: &out)
        commit(out, name)
        return true
    }
}
