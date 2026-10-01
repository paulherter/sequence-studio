import Foundation

/// Marker colours as in Premiere's marker dialog.
public enum MarkerColor: String, Sendable, Hashable, Codable, CaseIterable {
    case green, red, purple, orange, yellow, white, blue, cyan
}

public struct Marker: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var time: Time
    public var name: String
    public var color: MarkerColor
    public var comment: String
    /// Zero = a point marker.
    public var duration: Time

    public init(id: UUID = UUID(), time: Time, name: String = "", color: MarkerColor = .green,
                comment: String = "", duration: Time = .zero) {
        self.id = id; self.time = time; self.name = name
        self.color = color; self.comment = comment; self.duration = duration
    }

    private enum CodingKeys: String, CodingKey { case id, time, name, color, comment, duration }

    // Files written before colour, comment and duration existed decode with the defaults.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), time: try c.decode(Time.self, forKey: .time),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  color: try c.decodeIfPresent(MarkerColor.self, forKey: .color) ?? .green,
                  comment: try c.decodeIfPresent(String.self, forKey: .comment) ?? "",
                  duration: try c.decodeIfPresent(Time.self, forKey: .duration) ?? .zero)
    }
}
