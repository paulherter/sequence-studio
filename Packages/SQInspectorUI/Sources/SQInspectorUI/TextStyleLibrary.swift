import Foundation
import SQCore
import SQText

/// One text style in the Text panel: a name and a look. A view of a `Look` that shows only its style (font, size,
/// weight, fill, outline, background, shadow, alignment, spacing).
public struct TextStyleEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var style: TextStyle
    public var isBuiltIn: Bool

    public init(id: String, name: String, style: TextStyle, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.style = style; self.isBuiltIn = isBuiltIn
    }

    init(_ look: Look) { self.init(id: look.id, name: look.name, style: look.style, isBuiltIn: look.isBuiltIn) }
}

/// The styles of the Text panel: the Look library (`LookLibrary`) seen as styles. Built-in Looks are read-only, the
/// saved ones follow in creation order. Editing a style changes only the style of its Look; what else the Look holds
/// (an animation, a word highlight) stays.
public struct TextStyleLibrary: Hashable, Sendable {
    public private(set) var looks: LookLibrary
    /// The Look library as this copy was read from the store (empty for one made in memory): saving applies only what
    /// the copy changed against it, so an old copy never removes a Look it has not seen. Not part of equality.
    public let base: LookLibrary

    public init(looks: LookLibrary, base: LookLibrary = LookLibrary()) { self.looks = looks; self.base = base }

    public init(user: [TextStyleEntry] = []) {
        self.init(looks: LookLibrary(user: user.map { Look(id: $0.id, name: $0.name, style: $0.style) }))
    }

    public static func == (a: Self, b: Self) -> Bool { a.looks == b.looks }
    public func hash(into hasher: inout Hasher) { hasher.combine(looks) }

    public var user: [TextStyleEntry] { looks.user.map(TextStyleEntry.init) }
    public var entries: [TextStyleEntry] { looks.looks.map(TextStyleEntry.init) }

    public func entry(_ id: String) -> TextStyleEntry? { looks.look(id).map(TextStyleEntry.init) }

    /// The id of the first style whose look equals `style` exactly (user styles first, so a saved copy wins).
    public func match(_ style: TextStyle) -> String? { looks.match(style) }

    /// Saves `style` under a trimmed `name`; nil for an empty name.
    @discardableResult
    public mutating func add(name: String, style: TextStyle) -> String? { looks.add(name: name, style: style) }

    @discardableResult
    public mutating func rename(_ id: String, to name: String) -> Bool { looks.rename(id, to: name) }

    @discardableResult
    public mutating func update(_ id: String, style: TextStyle) -> Bool { looks.update(id, style: style) }

    @discardableResult
    public mutating func delete(_ id: String) -> Bool { looks.delete(id) }

    /// An editable copy ("Name Copy", "Name Copy 2", ...) of any style, built-in or not.
    public mutating func duplicate(_ id: String) -> String? { looks.duplicate(id) }

    public static let builtIns: [TextStyleEntry] = LookLibrary.builtIns.map(TextStyleEntry.init)
}

/// Reads and writes the Text panel's styles: a view of the Look store (`LookStore`). The default URL is the app's one
/// Look file; another URL is a Look file of its own (a file in the old `text-styles.json` format is read too).
/// Unreadable or missing file = no user styles; never throws on load.
public enum TextStyleStore {
    public static var defaultURL: URL { LookStore.defaultURL }

    private static func store(_ url: URL) -> LookStore { url == LookStore.defaultURL ? .shared : LookStore(url: url) }

    public static func load(from url: URL = defaultURL) -> TextStyleLibrary {
        let looks = store(url).library
        return TextStyleLibrary(looks: looks, base: looks)
    }

    /// Applies what `library` changed since it was loaded; Looks changed elsewhere in the meantime are kept.
    public static func save(_ library: TextStyleLibrary, to url: URL = defaultURL) throws {
        try store(url).replace(with: library.looks, base: library.base)
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

// shortcut: thumbnails are Mac-only (CGImage from the Core Text renderer); give them a draw-list image when the
// Windows Look popup shows previews.
/// Style thumbnails: the look drawn with the real text renderer, cached per (look, text).
@MainActor
public final class TextStyleThumbnails {
    public static let shared = TextStyleThumbnails()
    /// How many images were actually rendered (cache misses); tests read it.
    public private(set) var renderCount = 0
    private var cache: [String: CGImage] = [:]
    private var misses: Set<String> = []

    public init() {}

    /// Short clip text (up to 18 characters, one line) is shown as it is; anything else shows "Aa".
    public nonisolated static func sample(forClipText text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 18, !t.contains(where: \.isNewline) else { return "Aa" }
        return t
    }

    /// Cache key: the whole look plus the text (any change of either re-renders).
    public nonisolated static func key(style: TextStyle, text: String) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = (try? enc.encode(style)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return text + "\u{1F}" + json
    }

    /// The rendered image (transparent background, the style's own size), nil when nothing is drawn.
    public func image(style: TextStyle, text: String) -> CGImage? {
        let k = Self.key(style: style, text: text)
        if let hit = cache[k] { return hit }
        if misses.contains(k) { return nil }
        renderCount += 1
        var s = style
        s.secondLine = nil
        if let img = (try? TextRenderer.render(text: text, style: s, maxWidth: nil))?.image {
            if cache.count > 200 { cache.removeAll() }
            cache[k] = img
            return img
        }
        misses.insert(k)
        return nil
    }
}
#endif
