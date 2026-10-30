import Foundation
import SQCore

/// A Look: a named, saved appearance. One type for captions, text clips and graphic text items.
/// It never stores text content. `style` is always there; the rest is optional and only applied where it means something:
/// `animation` (nil = applying the Look leaves the item's animation alone), `karaoke` (the word highlight of caption
/// tracks) and `captionSegmentation` (how Create Captions splits lines; opaque JSON of the transcribe preset, which this
/// module does not know).
public struct Look: Sendable, Hashable, Codable, Identifiable {
    /// 1 = the caption look (style + animation), read by every build. 2 = everything a Look can hold.
    public static let payloadVersion = 2

    public var id: String
    public var name: String
    public var style: TextStyle
    public var animation: KeyframeTemplate?
    public var karaoke: KaraokeStyle?
    public var captionSegmentation: Data?
    /// Shipped with the app: read-only, never persisted.
    public var isBuiltIn: Bool
    /// Optional group of the Look strip's filter ("Bold", "Clean"). Lives in the Look store file only (an optional key old
    /// builds ignore); the project's kit payload does not carry it, so a project Look has none.
    public var category: String?

    public init(id: String, name: String, style: TextStyle, animation: KeyframeTemplate? = nil, karaoke: KaraokeStyle? = nil,
                captionSegmentation: Data? = nil, isBuiltIn: Bool = false, category: String? = nil) {
        self.id = id; self.name = name; self.style = style; self.animation = animation; self.karaoke = karaoke
        self.captionSegmentation = captionSegmentation; self.isBuiltIn = isBuiltIn; self.category = category
    }

    public init(id: String, name: String, captionLook: CaptionLook) {
        self.init(id: id, name: name, style: captionLook.style, animation: captionLook.animation)
    }

    private enum CodingKeys: String, CodingKey { case id, name, style, animation, karaoke, captionSegmentation, category }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  style: try c.decode(TextStyle.self, forKey: .style),
                  animation: try c.decodeIfPresent(KeyframeTemplate.self, forKey: .animation),
                  karaoke: try c.decodeIfPresent(KaraokeStyle.self, forKey: .karaoke),
                  captionSegmentation: try c.decodeIfPresent(Data.self, forKey: .captionSegmentation),
                  category: try c.decodeIfPresent(String.self, forKey: .category))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(style, forKey: .style)
        try c.encodeIfPresent(animation, forKey: .animation)
        try c.encodeIfPresent(karaoke, forKey: .karaoke)
        try c.encodeIfPresent(captionSegmentation, forKey: .captionSegmentation)
        try c.encodeIfPresent(category, forKey: .category)
    }

    /// What the Look looks like, without its id and name. Two Looks with equal values are the same Look twice.
    /// "No animation" reads the same whether it is stored as nil or as the empty template.
    public struct Values: Hashable, Sendable {
        public var style: TextStyle
        public var animation: KeyframeTemplate?
        public var karaoke: KaraokeStyle?
        public var captionSegmentation: Data?
    }

    public var values: Values {
        Values(style: style, animation: animation == KeyframeTemplate.none ? nil : animation, karaoke: karaoke,
               captionSegmentation: captionSegmentation)
    }

    /// The Look as captions render it (no animation = the empty template).
    public var captionLook: CaptionLook { CaptionLook(style: style, animation: animation ?? .none) }

    /// True when an item this Look was applied to no longer shows it: its style differs, or the Look carries an
    /// animation and the item's animation differs. A Look without an animation never looks at the item's animation.
    public func differs(fromStyle style: TextStyle, animation: KeyframeTemplate? = nil) -> Bool {
        if style != self.style { return true }
        guard let mine = self.animation else { return false }
        return (mine == .none ? nil : mine) != (animation == KeyframeTemplate.none ? nil : animation)
    }

    // MARK: Payload (how a project's kit stores a Look)

    private struct Payload: Codable {
        var style: TextStyle
        var animation: KeyframeTemplate?
        var karaoke: KaraokeStyle?
        var captionSegmentation: Data?
    }

    /// The stored form and its version: a Look that is exactly a caption look (style + animation) is written as
    /// version 1, byte-compatible with older builds; anything else as version 2.
    public func payload() throws -> (data: Data, version: Int) {
        if let animation, karaoke == nil, captionSegmentation == nil {
            return (try CaptionLook(style: style, animation: animation).payload(), CaptionLook.payloadVersion)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let p = Payload(style: style, animation: animation, karaoke: karaoke, captionSegmentation: captionSegmentation)
        return (try enc.encode(p), Self.payloadVersion)
    }

    public init(id: String, name: String, payload: Data, version: Int) throws {
        guard version <= Self.payloadVersion else { throw CaptionLookError.newerVersion }
        if version <= CaptionLook.payloadVersion {
            self.init(id: id, name: name, captionLook: try CaptionLook(payload: payload, version: version))
        } else {
            let p = try JSONDecoder().decode(Payload.self, from: payload)
            self.init(id: id, name: name, style: p.style, animation: p.animation, karaoke: p.karaoke,
                      captionSegmentation: p.captionSegmentation)
        }
    }
}

/// How an item relates to the Look that was applied to it.
public enum LookState: Hashable, Sendable {
    /// No Look applied (or the Look no longer exists).
    case none
    /// The item shows the Look exactly.
    case applied(String)
    /// The item was changed after the Look was applied ("edited": Update Look / Save as New Look).
    case edited(String)

    public var lookID: String? {
        switch self {
        case .none: nil
        case .applied(let id), .edited(let id): id
        }
    }

    public var isEdited: Bool { if case .edited = self { true } else { false } }
}

/// The Look library: the built-in Looks (read-only) plus saved ones in creation order. A value; `LookStore` (app) and
/// `StyleKit.looks` (project) persist it.
public struct LookLibrary: Sendable, Hashable, Codable {
    public static let formatVersion = 1

    public private(set) var user: [Look]
    /// Ids of Looks that were merged into an equal one (old id -> kept id), so what referred to the old id still resolves.
    public private(set) var aliases: [String: String]

    public init(user: [Look] = [], aliases: [String: String] = [:]) {
        self.user = []
        self.aliases = [:]
        for var l in user where look(l.id) == nil { l.isBuiltIn = false; self.user.append(l) }
        for (old, kept) in aliases where look(old) == nil && self.user.contains(where: { $0.id == kept }) { self.aliases[old] = kept }
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, looks, aliases }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard version <= Self.formatVersion else { throw CaptionLookError.newerVersion }
        self.init(user: try c.decodeIfPresent([Look].self, forKey: .looks) ?? [],
                  aliases: try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(user, forKey: .looks)
        if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
    }

    // MARK: List

    /// Built-in Looks first, then the saved ones.
    public var looks: [Look] { Self.builtIns + user }

    /// The Look under `id`; an id that was merged away resolves to the Look that replaced it.
    public func look(_ id: String) -> Look? {
        if let b = Self.builtIns.first(where: { $0.id == id }) { return b }
        let key = aliases[id] ?? id
        return user.first { $0.id == key }
    }

    /// The id of the first Look whose style equals `style` exactly (saved Looks first, so a saved copy wins).
    public func match(_ style: TextStyle) -> String? {
        (user + Self.builtIns).first { $0.style == style }?.id
    }

    /// Whether an item with `style` (and `animation`) still shows the Look applied to it.
    public func state(style: TextStyle, animation: KeyframeTemplate? = nil, appliedLookID: String?) -> LookState {
        guard let id = appliedLookID, let l = look(id) else { return .none }
        return l.differs(fromStyle: style, animation: animation) ? .edited(l.id) : .applied(l.id)
    }

    // MARK: Edit

    /// "Save as New Look": saves the values under a trimmed `name`; nil for an empty name or a taken `id`.
    @discardableResult
    public mutating func add(name: String, style: TextStyle, animation: KeyframeTemplate? = nil, karaoke: KaraokeStyle? = nil,
                             captionSegmentation: Data? = nil, id: String? = nil) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let id, look(id) != nil { return nil }
        let newID = id ?? freshID()
        user.append(Look(id: newID, name: n, style: style, animation: animation, karaoke: karaoke,
                         captionSegmentation: captionSegmentation))
        return newID
    }

    @discardableResult
    public mutating func rename(_ id: String, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = index(id) else { return false }
        user[i].name = n
        return true
    }

    /// "Update Look": changes the values of a saved Look in place (its id and name stay).
    @discardableResult
    public mutating func update(_ id: String, _ change: (inout Look) -> Void) -> Bool {
        guard let i = index(id) else { return false }
        var l = user[i]
        change(&l)
        (l.id, l.name, l.isBuiltIn) = (user[i].id, user[i].name, false)
        user[i] = l
        return true
    }

    @discardableResult
    public mutating func update(_ id: String, style: TextStyle) -> Bool { update(id) { $0.style = style } }

    /// Deletes a saved Look. An id that was merged into another Look only stops resolving: the Look it pointed at stays.
    @discardableResult
    public mutating func delete(_ id: String) -> Bool {
        if aliases[id] != nil, !user.contains(where: { $0.id == id }) { aliases[id] = nil; return true }
        guard let i = index(id) else { return false }
        let gone = user.remove(at: i).id
        aliases = aliases.filter { $0.value != gone }
        return true
    }

    /// An editable copy ("Name Copy", "Name Copy 2", ...) of any Look, built-in or not.
    public mutating func duplicate(_ id: String) -> String? {
        guard let src = look(id) else { return nil }
        var base = src.name
        if let r = base.range(of: #" Copy( \d+)?$"#, options: .regularExpression) { base.removeSubrange(r) }
        let names = Set(looks.map(\.name))
        var name = "\(base) Copy", n = 2
        while names.contains(name) { name = "\(base) Copy \(n)"; n += 1 }
        return add(name: name, style: src.style, animation: src.animation, karaoke: src.karaoke,
                   captionSegmentation: src.captionSegmentation)
    }

    /// Moves the saved Looks into the order of `ids` (unknown ids are ignored, Looks not named keep their place at the end).
    public mutating func reorder(_ ids: [String]) {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        user = user.enumerated().sorted {
            (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset)
        }.map(\.element)
    }

    /// Takes Looks from another store in (the migration of the old separate stores, an import). Returns where each
    /// incoming id ended up.
    /// - A Look whose values equal a saved one is not added: its id becomes an alias of the saved Look.
    /// - A different Look under a taken name gets a number ("Name 2").
    /// - A different Look under a taken id gets a new id.
    @discardableResult
    public mutating func merge(_ incoming: [Look]) -> [String: String] {
        var map: [String: String] = [:]
        for var l in incoming {
            l.isBuiltIn = false
            if let same = user.first(where: { $0.values == l.values }) {
                if same.id != l.id, look(l.id) == nil { aliases[l.id] = same.id }
                map[l.id] = same.id
                continue
            }
            let old = l.id
            if look(l.id) != nil { l.id = freshID() }
            let names = Set(looks.map(\.name))
            if names.contains(l.name) || l.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let base = l.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Look" : l.name
                var n = 2
                while names.contains("\(base) \(n)") { n += 1 }
                l.name = names.contains(base) ? "\(base) \(n)" : base
            }
            user.append(l)
            map[old] = l.id
        }
        return map
    }

    /// The saved Look under `id`; an id that was merged away finds the Look that replaced it (rename, update).
    private func index(_ id: String) -> Int? {
        let key = aliases[id] ?? id
        return user.firstIndex { $0.id == key }
    }

    private func freshID() -> String {
        var id: String
        repeat { id = UUID().uuidString } while look(id) != nil
        return id
    }

    // MARK: Built-in Looks

    public static let builtIns: [Look] = {
        func black(_ a: Double) -> RGBAColor { RGBAColor(red: 0, green: 0, blue: 0, alpha: a) }
        let font = TextStyle.defaultFontName
        let soft = TextShadow(color: black(0.55), angle: 135, distance: 3, blur: 8)
        let title = TextStyle(fontName: font, size: 72, weight: .bold, color: .white, shadow: soft, alignment: .center, lineSpacing: 2)
        let classic = TextStyle(fontName: font, size: 56, weight: .semibold, color: .white,
                                shadow: TextShadow(color: black(0.6), offsetX: 0, offsetY: 2, blur: 6),
                                alignment: .center, lineSpacing: 4)
        let box = TextStyle(fontName: font, size: 52, weight: .bold, color: .white,
                            background: TextBackground(color: black(0.75), padding: BoxPadding(horizontal: 20, vertical: 10), cornerRadius: 12),
                            alignment: .center, lineSpacing: 4)
        let outline = TextStyle(fontName: font, size: 60, weight: .heavy, color: .white,
                                stroke: TextStroke(color: .black, width: 6), alignment: .center, lineSpacing: 2)
        let tiktok = TextStyle(fontName: font, size: 64, weight: .black, color: .white,
                               stroke: TextStroke(color: .black, width: 8), shadow: soft, alignment: .center, lineSpacing: 2)
        let pill = CaptionPill.apply(to: TextStyle(fontName: font, size: 64, weight: .black, color: .white,
                                                   alignment: .center, lineSpacing: 2))
        let yellow = TextStyle(fontName: font, size: 64, weight: .black, color: RGBAColor(red: 1, green: 0.84, blue: 0.04, alpha: 1),
                               stroke: TextStroke(color: .black, width: 8), alignment: .center, lineSpacing: 2)
        let lower = TextStyle(fontName: font, size: 44, weight: .semibold, color: .white,
                              background: TextBackground(color: RGBAColor(red: 0.04, green: 0.42, blue: 1, alpha: 0.85),
                                                         padding: BoxPadding(horizontal: 18, vertical: 8), cornerRadius: 4),
                              alignment: .left, lineSpacing: 2)
        let minimal = TextStyle(fontName: font, size: 48, weight: .light, color: .white, alignment: .center,
                                lineSpacing: 2, tracking: 6, allCaps: true)
        let categories = ["title": "Bold", "bold-box": "Bold", "outline": "Bold", "tiktok": "Bold", "pill": "Bold", "yellow": "Bold",
                          "classic": "Clean", "lower-third": "Clean", "minimal": "Clean"]
        return [("title", "Title", title), ("classic", "Classic", classic), ("bold-box", "Bold Box", box),
                ("outline", "Outline", outline), ("tiktok", "TikTok", tiktok), ("pill", "Pill", pill),
                ("yellow", "Yellow", yellow), ("lower-third", "Lower Third", lower), ("minimal", "Minimal", minimal)]
            .map { Look(id: $0.0, name: $0.1, style: $0.2, isBuiltIn: true, category: categories[$0.0]) }
    }()
}

// MARK: - The Looks of a project (its style kit)

extension StyleKit {
    /// The kit Look under `id`, if this build can read it.
    public func look(_ id: String) -> Look? {
        looks[id].flatMap { try? Look(id: id, name: $0.name, payload: $0.payload, version: $0.payloadVersion) }
    }

    /// Every kit Look this build can read, by name (then id).
    public func projectLooks() -> [Look] {
        looks.keys.compactMap { look($0) }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Adds (or replaces) the Look under its id.
    public mutating func setLook(_ look: Look) throws {
        let p = try look.payload()
        looks[look.id] = StyleKitLook(name: look.name, payload: p.data, payloadVersion: p.version)
    }
}
