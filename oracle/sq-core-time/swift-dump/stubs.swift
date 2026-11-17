// Stand-ins for two internal symbols of ProjectFile+V77.swift that KeyframesModel.swift references. Neither runs in the
// dump (encoding / decoding of project files is not dumped), they only let the real KeyframesModel.swift compile alone.
import Foundation

final class HoldAheadSeen: Sendable {
    static let key = CodingUserInfoKey(rawValue: "sq.holdAheadSeen")!
    func mark() {}
}

extension KeyframeTrack {
    mutating func foldLegacyHoldHelpers() {}
}
