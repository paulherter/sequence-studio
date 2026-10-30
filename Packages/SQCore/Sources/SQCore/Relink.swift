import Foundation

/// A file found while searching a folder for offline media.
public struct RelinkCandidate: Sendable, Hashable {
    public var path: String
    public var size: Int64
    /// Content modification date when the scan knows it: breaks ties between several same-size files.
    public var modified: Date?
    /// Probed length when known (only `RelinkScorer` uses it; the name scan leaves it nil).
    public var duration: Time?
    public init(path: String, size: Int64, modified: Date? = nil, duration: Time? = nil) {
        self.path = path; self.size = size; self.modified = modified; self.duration = duration
    }
}

/// Matches offline media to files found in a folder: same file name (case-insensitive) AND the recorded size (a recorded size of 0 means unknown: an unambiguous name match is taken, see `MediaPathResolver.pick`).
/// A candidate whose size differs (or is unknown, -1) is never attached: it is a different file.
public enum RelinkPlanner {
    public struct Result: Sendable, Equatable {
        public var plan: [MediaRef.ID: String] = [:]
        /// Media for which files of that name exist, but none with the recorded size.
        public var sizeMismatch: [MediaRef.ID] = []
    }

    public static func plan(missing: [MediaRef], candidates: [RelinkCandidate]) -> [MediaRef.ID: String] {
        match(missing: missing, candidates: candidates).plan
    }

    public static func match(missing: [MediaRef], candidates: [RelinkCandidate]) -> Result {
        var byName: [String: [RelinkCandidate]] = [:]
        for c in candidates { byName[MediaPathResolver.fileName(of: c.path).lowercased(), default: []].append(c) }
        var out = Result()
        for m in missing {
            let name = MediaPathResolver.fileName(of: m.path).lowercased()   // Windows paths from Premiere too
            guard let list = byName[name], !list.isEmpty else { continue }
            if m.fingerprint.size == 0 {   // size unknown (Premiere import): name decides, ties by the stored folders
                if let p = MediaPathResolver.pick(list, for: m.path, size: nil) { out.plan[m.id] = p } else { out.sizeMismatch.append(m.id) }
            } else if let hit = best(list.filter { $0.size >= 0 && $0.size == m.fingerprint.size }, for: m) { out.plan[m.id] = hit.path }
            else { out.sizeMismatch.append(m.id) }
        }
        return out
    }

    /// The best of several same-name, same-size files, always the same one whatever order the scan met them in:
    /// same modification date as recorded, then the most matching trailing folder names, then the most shared leading
    /// folders (the closest path to where the file was), then the path itself.
    static func best(_ list: [RelinkCandidate], for m: MediaRef) -> RelinkCandidate? {
        guard list.count > 1 else { return list.first }
        let want = MediaPathResolver.folders(of: m.path).map { $0.lowercased() }
        func key(_ c: RelinkCandidate) -> (Int, Int, Int) {
            var date = 0
            if let a = c.modified, let b = m.fingerprint.modified, abs(a.timeIntervalSince(b)) < 1 { date = 1 }
            let have = MediaPathResolver.folders(of: c.path).map { $0.lowercased() }
            let tail = zip(have.reversed(), want.reversed()).prefix { $0 == $1 }.count
            let head = zip(have, want).prefix { $0 == $1 }.count
            return (date, tail, head)
        }
        return list.min { a, b in
            let ka = key(a), kb = key(b)
            if ka != kb { return ka > kb }
            return a.path < b.path
        }
    }
}

extension Project {
    /// Media whose file is not at its path.
    public func missingMedia(fileManager: FileManager = .default) -> [MediaRef] {
        media.filter { $0.status(fileManager: fileManager) == .missing }
    }

    /// Media among `paths` that a pending v10 Scale step waits on (H6) and that has no probe info: the caller probes the
    /// new files (off the main thread) and passes the results to `relink(_:probed:)`.
    public func mediaAwaitingProbeForPendingScale(_ paths: [MediaRef.ID: String]) -> [MediaRef.ID] {
        let waiting = Set(timelines.flatMap { $0.tracks.flatMap { $0.clips.filter(\.pendingSourcePixelScale).map(\.media) } })
        return media.filter { paths[$0.id] != nil && $0.info == nil && waiting.contains($0.id) }.map(\.id)
    }

    /// Media among `paths` without probe info (Premiere-import placeholders for files missing at import, very old
    /// projects): the caller probes the new files off the main thread and folds the results in with `adoptProbedInfo`.
    public func mediaAwaitingProbe(_ paths: [MediaRef.ID: String]) -> [MediaRef.ID] {
        media.filter { paths[$0.id] != nil && $0.info == nil }.map(\.id)
    }

    /// Makes unprobed media usable like a fresh import: info, length and (when given) the fingerprint of the new file;
    /// its clips learn their media length, and a still's clips become still clips (source from 0: a Premiere still's
    /// in point is a huge number). The owed v10 Scale step follows. Media that already has info is left alone.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func adoptProbedInfo(_ found: [MediaRef.ID: MediaInfo], fingerprints: [MediaRef.ID: MediaFingerprint] = [:]) -> Bool {
        var adopted = [MediaRef.ID: MediaInfo]()
        for i in media.indices where media[i].info == nil {
            guard let info = found[media[i].id] else { continue }
            media[i].info = info
            if media[i].duration == nil { media[i].duration = info.duration }
            if let fp = fingerprints[media[i].id] { media[i].fingerprint = fp }
            adopted[media[i].id] = info
        }
        guard !adopted.isEmpty else { return false }
        for ti in timelines.indices {
            for tr in timelines[ti].tracks.indices {
                for c in timelines[ti].tracks[tr].clips where !c.isGenerator && c.sequence == nil {
                    guard let info = adopted[c.media] else { continue }
                    var n = c
                    if n.mediaDuration == nil { n.mediaDuration = info.duration }
                    if info.isStill, !n.isStill {
                        // Clip markers are source time: they move with the source offset the still loses.
                        let offset = n.source.start
                        n.markers = n.markers?.map { m in var x = m; x.time = m.time - offset; return x }
                        n.isStill = true; n.source.start = .zero
                    }
                    if n != c { timelines[ti].tracks[tr].replace(n) }
                }
            }
        }
        applyPendingScaleMigration()
        return true
    }

    /// Points media at new files (unknown IDs ignored). The stale bookmark is dropped; clips are untouched except for
    /// the owed v10 Scale step (H6): `probed` fills in missing probe info of the new files, then every pending clip
    /// whose picture size is now known is converted. A chosen audio channel map is fitted to the probed file.
    public mutating func relink(_ paths: [MediaRef.ID: String], probed: [MediaRef.ID: MediaInfo] = [:]) {
        for i in media.indices {
            guard let p = paths[media[i].id] else { continue }
            media[i].path = p
            media[i].bookmark = nil
            if media[i].info == nil, let info = probed[media[i].id] { media[i].info = info }
        }
        mergeSharedPaths(moved: Set(paths.keys))   // a path another item holds: one file is one asset
        fitAudioChannelMaps(to: probed.filter { paths[$0.key] != nil })   // F7.10: a map the new file cannot play is cleared
        applyPendingScaleMigration()
    }
}
