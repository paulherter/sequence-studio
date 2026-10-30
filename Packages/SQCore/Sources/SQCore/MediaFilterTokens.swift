import Foundation

/// One fact typed into the Project panel's search field (`cam:FX3`, `fps:24`, `day:today`, `label:rose`, `kind:video`,
/// `unused`). Display only: it filters, nothing moves. Saved inside a Smart Folder (`SmartBin.tokens`).
public struct MediaFilterToken: Sendable, Hashable, Codable {
    public enum Key: String, Sendable, Hashable, Codable, CaseIterable {
        case camera = "cam", fps, day, label, kind, usage
    }
    public var key: Key
    /// Camera text, frame rate, `today` / `yesterday` / `yyyy-MM-dd`, label name, `video|audio|image`, `used|unused`.
    public var value: String

    public init(_ key: Key, _ value: String) { self.key = key; self.value = value }

    /// Typed form; parses back to the same token.
    public var text: String {
        if key == .usage { return value }
        let v = value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
        return "\(key.rawValue):\(v)"
    }

    /// Chip title.
    public var title: String {
        switch key {
        case .camera: "Camera: \(value)"
        case .fps: "\(value) fps"
        case .day: "Day: \(value.capitalized)"
        case .label: "Label: \(Self.label(named: value)?.displayName ?? value)"
        case .kind, .usage: value.capitalized
        }
    }

    // MARK: Parse

    /// Token for one word `key:value` or `unused` / `used`; nil when it is plain text or the value is empty or invalid.
    public static func parse(_ word: String) -> MediaFilterToken? {
        let lower = word.lowercased()
        if lower == "unused" || lower == "used" { return MediaFilterToken(.usage, lower) }
        guard let colon = word.firstIndex(of: ":"),
              let key = Key(rawValue: word[..<colon].lowercased()), key != .usage else { return nil }
        var value = String(word[word.index(after: colon)...])
        if value.hasPrefix("\"") { value.removeFirst(); if value.hasSuffix("\"") { value.removeLast() } }
        value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        switch key {
        case .fps: guard Double(value) != nil else { return nil }
        case .label: guard Self.label(named: value) != nil else { return nil }
        case .kind: guard ["video", "audio", "image"].contains(value.lowercased()) else { return nil }
        case .day: guard Self.dayOffset(value) != nil || Self.dayComponents(value) != nil else { return nil }
        default: break
        }
        return MediaFilterToken(key, key == .camera ? value : value.lowercased())
    }

    /// Splits `text` into words (a quoted value stays whole). `complete` is false for a trailing word the user may still
    /// be typing (no space after it).
    static func words(_ text: String) -> [(word: String, complete: Bool)] {
        var out: [(String, Bool)] = []
        var cur = "", quoted = false
        for ch in text {
            if ch == "\"" { quoted.toggle(); cur.append(ch) }
            else if ch.isWhitespace, !quoted { if !cur.isEmpty { out.append((cur, true)); cur = "" } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append((cur, false)) }
        return out
    }

    /// Pulls the finished tokens out of a typed string. Returns the remaining free text and the tokens found.
    /// A last word without a trailing space becomes a token only when `final` (Return, field loses focus).
    public static func extract(from text: String, final: Bool = false) -> (rest: String, tokens: [MediaFilterToken]) {
        var rest: [String] = [], tokens: [MediaFilterToken] = []
        for (word, complete) in words(text) {
            if complete || final, let t = parse(word) { tokens.append(t) } else { rest.append(word) }
        }
        let tail = text.last?.isWhitespace == true && !rest.isEmpty ? " " : ""
        return (rest.joined(separator: " ") + tail, tokens)
    }

    // MARK: Match

    static func label(named name: String) -> LabelColor? {
        let n = name.lowercased()
        return LabelColor.allCases.first { $0.rawValue == n || $0.displayName.lowercased() == n }
    }

    /// 0 = today, -1 = yesterday.
    private static func dayOffset(_ v: String) -> Int? {
        switch v.lowercased() { case "today": 0; case "yesterday": -1; default: nil }
    }

    private static func dayComponents(_ v: String) -> DateComponents? {
        let parts = v.split(separator: "-")
        let p = parts.compactMap { Int($0) }
        guard parts.count == 3, p.count == 3 else { return nil }
        return DateComponents(year: p[0], month: p[1], day: p[2])
    }

    /// Whether `media` passes. `isUsed` comes from the caller; `now` and `calendar` decide `day:`.
    public func matches(_ media: MediaRef, isUsed: Bool, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch key {
        case .usage: return value == "used" ? isUsed : !isUsed
        case .camera: return media.info?.cameraModel?.localizedCaseInsensitiveContains(value) ?? false
        case .fps:
            guard let v = media.info?.video, let want = Double(value), v.nominalFrameDuration.value > 0 else { return false }
            let fps = Double(v.nominalFrameDuration.timescale) / Double(v.nominalFrameDuration.value)
            return value.contains(".") ? abs(fps - want) < 0.01 : fps.rounded() == want.rounded()
        case .label: return Self.label(named: value).map { media.label == $0 } ?? false
        case .kind:
            switch (value, media.kind) {
            case ("video", .video), ("video", .videoAudio), ("audio", .audio), ("image", .image): return true
            default: return false
            }
        case .day:
            guard let shot = media.shootDate else { return false }
            if let off = Self.dayOffset(value) {
                guard let d = calendar.date(byAdding: .day, value: off, to: now) else { return false }
                return calendar.isDate(shot, inSameDayAs: d)
            }
            guard let c = Self.dayComponents(value), let d = calendar.date(from: c) else { return false }
            return calendar.isDate(shot, inSameDayAs: d)
        }
    }
}

extension MediaRef {
    /// When the clip was shot: the file's creation date, else its modification date (nil when neither is known).
    public var shootDate: Date? { info?.created ?? fingerprint.modified }
}

/// Free text plus tokens: what the search field and chips say together.
public struct MediaFilterQuery: Sendable, Hashable {
    public var text: String
    public var tokens: [MediaFilterToken]
    public init(text: String = "", tokens: [MediaFilterToken] = []) { self.text = text; self.tokens = tokens }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && tokens.isEmpty }

    /// Parses a whole string (all words count as complete).
    public static func parse(_ s: String) -> MediaFilterQuery {
        let r = MediaFilterToken.extract(from: s, final: true)
        return MediaFilterQuery(text: r.rest.trimmingCharacters(in: .whitespaces), tokens: r.tokens)
    }

    /// Tokens of different kinds all apply; two tokens of one kind (two cameras, two days) are alternatives.
    public func matches(_ media: MediaRef, isUsed: Bool, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, !media.name.localizedCaseInsensitiveContains(q) { return false }
        for key in Set(tokens.map(\.key)) {
            let same = tokens.filter { $0.key == key }
            let ok = key == .usage
                ? same.allSatisfy { $0.matches(media, isUsed: isUsed, now: now, calendar: calendar) }
                : same.contains { $0.matches(media, isUsed: isUsed, now: now, calendar: calendar) }
            if !ok { return false }
        }
        return true
    }

    /// Values that exist in `media` for a key (quick chips): cameras, frame rates, labels.
    public static func values(for key: MediaFilterToken.Key, in media: [MediaRef]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for m in media {
            var v: String?
            switch key {
            case .camera: v = m.info?.cameraModel
            case .fps:
                if let d = m.info?.video?.nominalFrameDuration, d.value > 0 {
                    let f = Double(d.timescale) / Double(d.value)
                    v = abs(f - f.rounded()) < 0.01 ? String(Int(f.rounded())) : String(format: "%.3f", f)
                }
            case .label: v = m.label?.rawValue
            default: break
            }
            if let v, seen.insert(v).inserted { out.append(v) }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
