import Foundation

/// A saved filter of the Project panel (smart bin): a name plus rules. It lists the media that match; nothing is moved.
/// Stored in `Project.smartBins` (optional key, absent = none; an older app ignores it).
public struct SmartBin: Sendable, Hashable, Codable, Identifiable {
    public enum Usage: String, Sendable, Hashable, Codable, CaseIterable { case any, used, unused }
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable { case any, video, audio, image }

    public var id: UUID
    public var name: String
    /// Text the media name must contain (case-insensitive); empty = any name.
    public var text: String
    public var usage: Usage
    public var kind: Kind
    /// Only media whose file is missing.
    public var offlineOnly: Bool
    public var label: LabelColor?
    /// Search-field tokens (camera, frame rate, day, ...); nil = none. Optional additive key.
    public var tokens: [MediaFilterToken]?
    /// The text also matches the spoken words (captions over the media), not only the name. nil/false = name only.
    public var searchesSpoken: Bool?

    public init(id: UUID = UUID(), name: String, text: String = "", usage: Usage = .any, kind: Kind = .any,
                offlineOnly: Bool = false, label: LabelColor? = nil, tokens: [MediaFilterToken]? = nil, searchesSpoken: Bool? = nil) {
        self.id = id; self.name = name; self.text = text; self.usage = usage; self.kind = kind
        self.offlineOnly = offlineOnly; self.label = label; self.tokens = tokens
        self.searchesSpoken = searchesSpoken
    }

    /// Whether `media` passes the rules. `isUsed` and `isOffline` come from the caller (offline needs the file system).
    public func matches(_ media: MediaRef, isUsed: Bool, isOffline: Bool, spoken: Set<MediaRef.ID> = [], now: Date = Date()) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, !media.name.localizedCaseInsensitiveContains(q),
           !(searchesSpoken == true && spoken.contains(media.id)) { return false }
        switch usage { case .any: break; case .used: if !isUsed { return false }; case .unused: if isUsed { return false } }
        if offlineOnly, !isOffline { return false }
        if let label, media.label != label { return false }
        if let tokens, !tokens.isEmpty, !MediaFilterQuery(tokens: tokens).matches(media, isUsed: isUsed, now: now) { return false }
        switch (kind, media.kind) {
        case (.any, _): break
        case (.video, .video), (.video, .videoAudio), (.audio, .audio), (.image, .image): break
        default: return false
        }
        return true
    }
}

extension Project {
    public var smartBinList: [SmartBin] { smartBins ?? [] }
    public func smartBin(_ id: SmartBin.ID) -> SmartBin? { smartBinList.first { $0.id == id } }

    /// Adds a smart bin; an empty name is refused.
    @discardableResult
    public mutating func addSmartBin(_ bin: SmartBin) -> Bool {
        guard !bin.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        smartBins = smartBinList + [bin]
        return true
    }

    @discardableResult
    public mutating func updateSmartBin(_ bin: SmartBin) -> Bool {
        guard var list = smartBins, let i = list.firstIndex(where: { $0.id == bin.id }),
              !bin.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        list[i] = bin; smartBins = list
        return true
    }

    @discardableResult
    public mutating func removeSmartBin(_ id: SmartBin.ID) -> Bool {
        guard var list = smartBins, let i = list.firstIndex(where: { $0.id == id }) else { return false }
        list.remove(at: i); smartBins = list.isEmpty ? nil : list
        return true
    }

    /// Fraction (0...1) of the media's duration that sequence clips use, ranges merged. 0 = unused, nil = unknown length.
    public func usedFraction(of media: MediaRef.ID) -> Double? {
        guard let total = self.media(media)?.duration, total > .zero else { return nil }
        var ranges: [TimeRange] = []
        for t in timelines { for tr in t.tracks { for c in tr.clips where c.media == media && !c.isNested && !c.isGenerator && !c.source.isEmpty {
            ranges.append(c.source)
        } } }
        guard !ranges.isEmpty else { return 0 }
        ranges.sort { $0.start < $1.start }
        var covered = Time.zero
        var cur = ranges[0]
        for r in ranges.dropFirst() {
            if r.start <= cur.end { if r.end > cur.end { cur = TimeRange(start: cur.start, end: r.end) } } else {
                covered = covered + cur.duration; cur = r
            }
        }
        covered = covered + cur.duration
        let f = Double(covered.value) / Double(covered.timescale) / (Double(total.value) / Double(total.timescale))
        return min(1, max(0, f))
    }
}
