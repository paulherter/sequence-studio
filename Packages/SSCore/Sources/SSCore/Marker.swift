import Foundation

public struct Marker: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var time: Time
    public var name: String

    public init(id: UUID = UUID(), time: Time, name: String = "") {
        self.id = id; self.time = time; self.name = name
    }
}
