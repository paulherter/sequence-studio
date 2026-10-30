import Foundation

public enum TextTemplateError: Error, Equatable, CustomStringConvertible {
    /// File was written by a newer app version.
    case unsupportedVersion(found: Int, supported: Int)
    case invalidData(String)

    public var description: String {
        switch self {
        case let .unsupportedVersion(found, supported):
            "Text template format version \(found) is newer than the supported version \(supported)."
        case let .invalidData(why): "Invalid text template: \(why)"
        }
    }
}

public struct TextTemplate: Sendable, Hashable, Codable {
    /// 4: the style may carry `secondLine` (N4 two-style text; older versions read as one style).
    /// 3: animations carry an `anchor` (start/end; older files read as start).
    /// 2: animation tracks use SQCore keyframes with template-local `Time`s (v1: normalized fractions + easing enum, still readable).
    public static let formatVersion = 4

    public var name: String
    public var text: String
    public var style: TextStyle
    public var animation: KeyframeTemplate?
    /// Area text: the wrap width and height of the box. Nil = point text (one line per paragraph, grows with the text).
    public var box: TextBox?
    /// Words drawn in another color (karaoke captions); nil for plain text.
    public var highlight: TextHighlight?
    /// Id of the Look that was applied last (`LookLibrary`); nil = none. Only a note for the "edited" state: the style
    /// above is what is drawn. An optional key, so older builds read the template as before.
    public var lookID: String?

    public init(name: String, text: String, style: TextStyle, animation: KeyframeTemplate? = nil, box: TextBox? = nil,
                highlight: TextHighlight? = nil, lookID: String? = nil) {
        self.name = name; self.text = text; self.style = style; self.animation = animation; self.box = box
        self.highlight = highlight; self.lookID = lookID
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, name, text, style, animation, box, highlight, lookID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        text = try c.decode(String.self, forKey: .text)
        style = try c.decode(TextStyle.self, forKey: .style)
        animation = try c.decodeIfPresent(KeyframeTemplate.self, forKey: .animation)
        box = try c.decodeIfPresent(TextBox.self, forKey: .box)
        highlight = try c.decodeIfPresent(TextHighlight.self, forKey: .highlight)
        lookID = try c.decodeIfPresent(String.self, forKey: .lookID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(name, forKey: .name)
        try c.encode(text, forKey: .text)
        try c.encode(style, forKey: .style)
        try c.encodeIfPresent(animation, forKey: .animation)
        try c.encodeIfPresent(box, forKey: .box)
        try c.encodeIfPresent(highlight, forKey: .highlight)
        try c.encodeIfPresent(lookID, forKey: .lookID)
    }

    /// Pretty-printed JSON with sorted keys (stable for diffs).
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Reads the version first, so newer files fail with `unsupportedVersion` even if their structure differs.
    public static func decode(from data: Data) throws -> TextTemplate {
        struct Peek: Decodable { let formatVersion: Int }
        let version: Int
        do { version = try JSONDecoder().decode(Peek.self, from: data).formatVersion }
        catch { throw TextTemplateError.invalidData("missing or unreadable formatVersion") }
        guard version >= 1 else { throw TextTemplateError.invalidData("formatVersion \(version)") }
        guard version <= formatVersion else { throw TextTemplateError.unsupportedVersion(found: version, supported: formatVersion) }
        do { return try JSONDecoder().decode(TextTemplate.self, from: data) }
        catch { throw TextTemplateError.invalidData(String(describing: error)) }
    }
}
