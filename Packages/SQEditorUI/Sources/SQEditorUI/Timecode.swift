import Foundation
import SQCore

/// Pure timecode format/parse on rational time. Drop-frame applies to 29.97 and 59.94 only.
public struct Timecode: Sendable, Hashable {
    public let frameDuration: Time
    public let dropFrame: Bool

    public init(frameDuration: Time, dropFrame: Bool) {
        self.frameDuration = frameDuration
        let nominal = Timecode.nominal(of: frameDuration)
        self.dropFrame = dropFrame && frameDuration.value == 1001 && (nominal == 30 || nominal == 60)
    }

    static func nominal(of fd: Time) -> Int64 {
        let v = max(fd.value, 1)
        return (fd.timescale * 2 + v) / (v * 2)
    }

    public var nominalFPS: Int64 { Timecode.nominal(of: frameDuration) }
    public var separatorBeforeFrames: Character { dropFrame ? ";" : ":" }
    private var dropCount: Int64 { nominalFPS / 15 }   // 2 at 30, 4 at 60

    public func format(_ time: Time) -> String {
        var n = time.frameIndex(frameDuration: frameDuration)
        let negative = n < 0
        if negative { n = -n }
        let fps = nominalFPS
        if dropFrame {
            let d = dropCount
            let per10 = fps * 600 - 9 * d
            let perMin = fps * 60 - d
            let tens = n / per10, rem = n % per10
            n += 9 * d * tens
            if rem > d { n += d * ((rem - d) / perMin) }
        }
        let f = n % fps
        let s = (n / fps) % 60
        let m = (n / (fps * 60)) % 60
        let h = n / (fps * 3600)
        func p(_ v: Int64) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(negative ? "-" : "")\(p(h)):\(p(m)):\(p(s))\(separatorBeforeFrames)\(p(f))"
    }

    /// Accepts `hh:mm:ss:ff` (`: ; . ,` as separators), shorter right-aligned forms ("1:01"),
    /// or bare digits right-aligned ("101" = 00:00:01:01). Nil for invalid input or dropped labels.
    public func parse(_ text: String) -> Time? {
        var s = text.trimmingCharacters(in: .whitespaces)
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        guard !s.isEmpty else { return nil }
        let seps: Set<Character> = [":", ";", ".", ","]
        var fields: [Int64] = []
        if s.contains(where: { seps.contains($0) }) {
            for part in s.split(omittingEmptySubsequences: false, whereSeparator: { seps.contains($0) }) {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int64(part) else { return nil }
                fields.append(v)
            }
            guard fields.count <= 4 else { return nil }
        } else {
            guard s.allSatisfy({ $0.isASCII && $0.isNumber }), s.count <= 8 else { return nil }
            let chars = Array(String(repeating: "0", count: 8 - s.count) + s)
            for i in stride(from: 0, to: 8, by: 2) { fields.append(Int64(String(chars[i..<i + 2]))!) }
        }
        while fields.count < 4 { fields.insert(0, at: 0) }
        let (h, m, sec, f) = (fields[0], fields[1], fields[2], fields[3])
        let fps = nominalFPS
        guard m < 60, sec < 60, f < fps else { return nil }
        var frames = fps * (3600 * h + 60 * m + sec) + f
        if dropFrame {
            let d = dropCount
            if sec == 0 && f < d && m % 10 != 0 { return nil }
            let totalMin = 60 * h + m
            frames -= d * (totalMin - totalMin / 10)
        }
        let t = frameDuration * frames
        return negative ? -t : t
    }
}
