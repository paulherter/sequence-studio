import Foundation

/// SMPTE timecode text (HH:MM:SS:FF, `;` before the frames for drop frame) as whole frame counts, for EDL interchange.
/// Integer math only. Drop frame skips 2 (30 fps) or 4 (60 fps) frame numbers each minute except every tenth.
public struct CMXTimecode: Sendable, Equatable {
    /// Frames per second as counted on the clock (24, 25, 30, 60...).
    public var nominalRate: Int
    public var dropFrame: Bool

    public init(nominalRate: Int, dropFrame: Bool = false) {
        self.nominalRate = max(nominalRate, 1)
        // Only 30 and 60 count NTSC frames; anything else cannot drop.
        self.dropFrame = dropFrame && nominalRate % 30 == 0
    }

    /// The clock rate and drop-frame choice for a sequence frame duration (29.97 / 59.94 -> drop frame).
    public init(frameDuration fd: Time, preferDrop: Bool = true) {
        let rate = Double(fd.timescale) / Double(max(fd.value, 1))
        let nominal = Int(rate.rounded())
        let ntsc = fd.value * Int64(nominal) != fd.timescale
        self.init(nominalRate: nominal, dropFrame: preferDrop && ntsc)
    }

    private var dropped: Int64 { dropFrame ? Int64(nominalRate / 15) : 0 }

    /// Frame count of a timecode string; nil when it is not `HH:MM:SS:FF` / `HH:MM:SS;FF`. The separator is not trusted:
    /// the receiver's `dropFrame` decides.
    public func frames(_ text: String) -> Int64? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard parts.count == 4 else { return nil }
        let v = parts.compactMap { Int64($0) }
        guard v.count == 4, v.allSatisfy({ $0 >= 0 }) else { return nil }
        let rate = Int64(nominalRate)
        let totalMinutes = v[0] * 60 + v[1]
        return (v[0] * 3600 + v[1] * 60 + v[2]) * rate + v[3] - dropped * (totalMinutes - totalMinutes / 10)
    }

    /// True when the text uses a `;` frame separator (the EDL's own drop-frame marker).
    public static func usesDropSeparator(_ text: String) -> Bool { text.contains(";") }

    public func string(frames: Int64) -> String {
        var n = max(frames, 0)
        let rate = Int64(nominalRate)
        if dropFrame {
            let perTen = rate * 600 - dropped * 9, perMinute = rate * 60 - dropped
            let tens = n / perTen, rest = n % perTen
            n += 9 * dropped * tens
            if rest > dropped { n += dropped * ((rest - dropped) / perMinute) }
        }
        let f = n % rate, s = (n / rate) % 60, m = (n / (rate * 60)) % 60, h = n / (rate * 3600)
        func two(_ x: Int64) -> String { x < 10 ? "0\(x)" : "\(x)" }
        return "\(two(h)):\(two(m)):\(two(s))\(dropFrame ? ";" : ":")\(two(f))"
    }
}
