import Foundation

/// One proposed match of an offline media item to a found file, with the signals that agree.
public struct RelinkProposal: Sendable, Hashable, Identifiable {
    public struct Signals: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Same file name (case-insensitive).
        public static let name = Signals(rawValue: 1)
        /// Same name once a copy suffix ("intro (1)", "intro copy") is removed.
        public static let similarName = Signals(rawValue: 2)
        public static let size = Signals(rawValue: 4)
        public static let duration = Signals(rawValue: 8)
        public static let modified = Signals(rawValue: 16)
        /// Trailing folder names agree (Day2/ stays Day2/).
        public static let folders = Signals(rawValue: 32)
    }
    public enum Tier: Sendable, Hashable { case strong, weak }

    public var mediaID: MediaRef.ID
    public var path: String
    public var score: Int
    public var signals: Signals
    /// The recorded size is known and the found file has another size.
    public var sizeDiffers: Bool
    /// Another file scored exactly the same for this item: the pick is stable but a guess.
    public var isAmbiguous: Bool
    public var id: MediaRef.ID { mediaID }

    public var tier: Tier { score >= RelinkScorer.strongScore && !sizeDiffers && !isAmbiguous ? .strong : .weak }
    /// Only strong matches start ticked; the user ticks weak ones on purpose.
    public var isChecked: Bool { tier == .strong }

    /// "name, size, length" for the checklist row.
    public var signalText: String {
        var parts: [String] = []
        if signals.contains(.name) { parts.append("name") } else if signals.contains(.similarName) { parts.append("similar name") }
        if signals.contains(.size) { parts.append("size") }
        if signals.contains(.duration) { parts.append("length") }
        if signals.contains(.modified) { parts.append("date") }
        if signals.contains(.folders) { parts.append("folders") }
        if isAmbiguous { parts.append("several equal files") }
        return parts.joined(separator: ", ")
    }
}

/// Scores found files against offline media (name, size, length, modification date, folder structure) so equal-size
/// files are told apart by more signals, never by scan order, and a weak match is shown, not applied. Pure: the
/// caller scans the disk and probes lengths. (Recorded start timecode is not stored on `MediaRef`: not a signal yet.)
public enum RelinkScorer {
    public struct Result: Sendable, Equatable {
        /// Best first (score, then item path), at most one per item and per file.
        public var proposals: [RelinkProposal] = []
        public var unmatched: [MediaRef.ID] = []
        public init(proposals: [RelinkProposal] = [], unmatched: [MediaRef.ID] = []) {
            self.proposals = proposals; self.unmatched = unmatched
        }

        /// "Found 11 of 12 missing files".
        public func foundText(total: Int) -> String {
            "Found \(proposals.count) of \(total) missing \(total == 1 ? "file" : "files")"
        }
    }

    static let strongScore = 60
    static let weakScore = 20
    static let durationTolerance = Time(1, 25)

    /// Whether probing the length of `c` can matter: it shares a name stem or the size with an item.
    public static func worthProbing(_ c: RelinkCandidate, for missing: [MediaRef]) -> Bool {
        let candidateStem = stem(of: c.path)
        return missing.contains { m in
            candidateStem == stem(of: m.path) || (m.fingerprint.size > 0 && m.fingerprint.size == c.size)
        }
    }

    public static func propose(missing: [MediaRef], candidates: [RelinkCandidate]) -> Result {
        struct Pair { var m: Int; var c: Int; var score: Int; var signals: RelinkProposal.Signals; var sizeDiffers: Bool }
        var perItem: [[Pair]] = Array(repeating: [], count: missing.count)
        for (mi, m) in missing.enumerated() {
            for (ci, c) in candidates.enumerated() {
                if let hit = score(m, c) { perItem[mi].append(Pair(m: mi, c: ci, score: hit.points, signals: hit.signals, sizeDiffers: hit.sizeDiffers)) }
            }
        }
        // An item is ambiguous when two different files tie for its best score.
        var ambiguous = Set<Int>()
        for (mi, list) in perItem.enumerated() {
            if let top = list.map(\.score).max(), list.filter({ $0.score == top }).count > 1 { ambiguous.insert(mi) }
        }
        let order = perItem.joined().sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if missing[a.m].path != missing[b.m].path { return missing[a.m].path < missing[b.m].path }
            return candidates[a.c].path < candidates[b.c].path
        }
        var usedItems = Set<Int>(), usedFiles = Set<Int>()
        var out = Result()
        for p in order where !usedItems.contains(p.m) && !usedFiles.contains(p.c) {
            usedItems.insert(p.m); usedFiles.insert(p.c)
            out.proposals.append(RelinkProposal(mediaID: missing[p.m].id, path: candidates[p.c].path, score: p.score, signals: p.signals,
                                                sizeDiffers: p.sizeDiffers, isAmbiguous: ambiguous.contains(p.m)))
        }
        out.unmatched = missing.indices.filter { !usedItems.contains($0) }.map { missing[$0].id }
        return out
    }

    /// nil when the file has nothing to do with the item.
    static func score(_ m: MediaRef, _ c: RelinkCandidate) -> (points: Int, signals: RelinkProposal.Signals, sizeDiffers: Bool)? {
        var s: RelinkProposal.Signals = []
        var points = 0
        let wantName = MediaPathResolver.fileName(of: m.path).lowercased(), haveName = MediaPathResolver.fileName(of: c.path).lowercased()
        if wantName == haveName { s.insert(.name); points += 40 }
        else if stem(of: m.path) == stem(of: c.path) { s.insert(.similarName); points += 20 }
        let known = m.fingerprint.size > 0 && c.size >= 0
        let sizeDiffers = known && m.fingerprint.size != c.size
        if known && !sizeDiffers { s.insert(.size); points += 30 }
        if let want = m.duration ?? m.info?.duration, let have = c.duration {
            let diff = want > have ? want - have : have - want
            if diff <= durationTolerance { s.insert(.duration); points += 20 }
        }
        if let a = c.modified, let b = m.fingerprint.modified, abs(a.timeIntervalSince(b)) < 1 { s.insert(.modified); points += 10 }
        let want = MediaPathResolver.folders(of: m.path).map { $0.lowercased() }
        let have = MediaPathResolver.folders(of: c.path).map { $0.lowercased() }
        let tail = zip(have.reversed(), want.reversed()).prefix { $0 == $1 }.count
        let head = zip(have, want).prefix { $0 == $1 }.count
        if tail > 0 { s.insert(.folders) }
        points += min(10, tail * 2 + head)
        // Some real link between the two: a name, or size and length together (a renamed copy).
        guard s.contains(.name) || s.contains(.similarName) || (s.contains(.size) && s.contains(.duration)) else { return nil }
        guard points >= weakScore else { return nil }
        return (points, s, sizeDiffers)
    }

    /// File name without extension, lower-cased, copy suffixes removed: "Intro (1).mov", "intro copy.mov" -> "intro".
    static func stem(of path: String) -> String {
        var name = MediaPathResolver.fileName(of: path)
        if let dot = name.lastIndex(of: "."), dot != name.startIndex { name = String(name[..<dot]) }
        name = name.lowercased()
        var changed = true
        while changed {
            changed = false
            for suffix in [" - copy", " copy", "_copy"] where name.hasSuffix(suffix) { name.removeLast(suffix.count); changed = true }
            if name.hasSuffix(")"), let open = name.lastIndex(of: "("), open != name.startIndex,
               name[name.index(before: open)] == " ", Int(name[name.index(after: open)..<name.index(before: name.endIndex)]) != nil {
                name = String(name[..<name.index(before: open)]); changed = true
            }
        }
        return name
    }
}

/// What the Library's health line shows: counts of media in the project folder, outside it, and offline.
public struct ProjectHealth: Sendable, Equatable {
    public var inFolder = 0
    public var outside = 0
    public var missing = 0
    public var isHealthy: Bool { outside == 0 && missing == 0 }
    public init(inFolder: Int = 0, outside: Int = 0, missing: Int = 0) {
        self.inFolder = inFolder; self.outside = outside; self.missing = missing
    }

    /// Distinct files; offline items count as missing only. A project without a project folder has no "outside".
    /// Touches the disk (symlink resolution in `isInside`): call off the main thread.
    public static func make(media: [MediaRef], offline: Set<MediaRef.ID>, projectURL: URL?) -> ProjectHealth {
        make(media: media, offline: offline, projectFolder: MediaManagement.projectFolder(forProjectAt: projectURL))
    }

    public static func make(media: [MediaRef], offline: Set<MediaRef.ID>, projectFolder: URL?) -> ProjectHealth {
        var h = ProjectHealth()
        guard let folder = projectFolder else {
            h.missing = media.filter { offline.contains($0.id) }.count
            return h
        }
        var seen = Set<String>()
        for m in media {
            if offline.contains(m.id) { h.missing += 1; continue }
            guard seen.insert(m.path).inserted else { continue }
            if MediaManagement.isInside(m.path, folder: folder) { h.inFolder += 1 } else { h.outside += 1 }
        }
        return h
    }
}
