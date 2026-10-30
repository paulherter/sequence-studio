import Foundation

/// Plans the short versions of a sequence (60/30/15/6 s) from marker ranges the editor set for it.
///
/// A cut-down marker is one named "cut-down" / "cutdown" / "cut down" or colored `cutDownColor`. A marker with a
/// duration is a range by itself; point markers pair up in time order (in, out). A range whose name holds a target
/// length ("cut-down 15") belongs to that target only, an untagged range is a candidate for every target.
public enum CutDownPlanner {
    public static let targetSeconds: [Int] = [60, 30, 15, 6]
    public static let cutDownColor: MarkerColor = .cyan

    public struct Plan: Sendable, Equatable, Identifiable {
        public enum Status: Sendable, Equatable {
            case exact          // total equals the target
            case short          // fits, but is shorter than the target
            case empty          // no range fits this target
        }
        public var targetSeconds: Int
        public var name: String
        public var ranges: [TimeRange]
        public var duration: Time
        public var status: Status
        public var id: Int { targetSeconds }
    }

    public static func isCutDownMarker(_ m: Marker) -> Bool {
        if m.color == cutDownColor { return true }
        let n = m.name.lowercased()
        return n.contains("cut-down") || n.contains("cutdown") || n.contains("cut down")
    }

    /// The ranges the cut-down markers describe, with the name of the marker that opened each.
    public static func ranges(from markers: [Marker]) -> [(name: String, range: TimeRange)] {
        let all = markers.filter(isCutDownMarker).sorted { $0.time < $1.time }
        var out: [(name: String, range: TimeRange)] = []
        var open: Marker?
        for m in all {
            if m.duration > .zero {
                out.append((m.name, TimeRange(start: m.time, duration: m.duration)))
            } else if let o = open {
                if m.time > o.time { out.append((o.name.isEmpty ? m.name : o.name, TimeRange(start: o.time, end: m.time))) }
                open = nil
            } else {
                open = m
            }
        }
        return out
    }

    /// The target length (seconds) a name asks for, if it holds one of `targets` as a whole number.
    static func taggedTarget(_ name: String, targets: [Int]) -> Int? {
        name.split { !$0.isNumber }.compactMap { Int($0) }.first { targets.contains($0) }
    }

    /// One plan per target. Ranges are taken in time order while the total stays within the target.
    public static func plans(from markers: [Marker], targets: [Int] = targetSeconds) -> [Plan] {
        let all = ranges(from: markers).map { (tag: taggedTarget($0.name, targets: targets), range: $0.range) }
        return targets.map { t in
            let limit = Time(seconds: Int64(t))
            var total = Time.zero
            var picked: [TimeRange] = []
            for c in all where c.tag == nil || c.tag == t {
                if total + c.range.duration <= limit {
                    picked.append(c.range)
                    total += c.range.duration
                }
            }
            let status: Plan.Status = picked.isEmpty ? .empty : (total == limit ? .exact : .short)
            return Plan(targetSeconds: t, name: "Cut-down \(t) s", ranges: picked, duration: total, status: status)
        }
    }
}
