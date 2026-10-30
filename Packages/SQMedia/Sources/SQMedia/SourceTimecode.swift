import Foundation
import SQCore

/// The timecode a camera recorded with the footage: time of day of the first frame, as an exact rational.
///
/// Sources, in this order: the QuickTime `tmcd` track (read at its own rate, which can differ from the picture's, and with
/// its drop-frame flag), Sony's `rtmd` track (cameras without `tmcd`), and the Broadcast Wave `bext` chunk (sample count
/// since midnight, audio files).
public struct SourceTimecode: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable { case tmcd, rtmd, bext }

    /// Time of day of the first frame / sample.
    public var origin: Time
    /// The clock the timecode counts on (the tmcd track's own frame duration, 1001/30000 for 29.97). nil for audio-only
    /// sources, which count samples.
    public var frameDuration: Time?
    public var dropFrame: Bool
    public var source: Source

    public init(origin: Time, frameDuration: Time?, dropFrame: Bool, source: Source) {
        self.origin = origin; self.frameDuration = frameDuration; self.dropFrame = dropFrame; self.source = source
    }

    /// Frames since midnight on `fd` (default: the timecode's own clock), rounded to the nearest frame.
    public func frameCount(on fd: Time? = nil) -> Int64? {
        guard let fd = fd ?? frameDuration, fd > .zero, origin >= .zero else { return nil }
        let n = Int128(origin.value) * Int128(fd.timescale), d = Int128(origin.timescale) * Int128(fd.value)
        return Int64(clamping: (2 * n + d) / (2 * d))
    }

    /// HH:MM:SS:FF (`;` before the frames for drop frame). `frameDuration`: the clock to show an audio source on.
    public func label(frameDuration fd: Time? = nil) -> String? {
        guard let clock = frameDuration ?? fd, let frames = frameCount(on: clock) else { return nil }
        let nominal = CMXTimecode(frameDuration: clock, preferDrop: false).nominalRate
        let drop = frameDuration != nil ? dropFrame : CMXTimecode(frameDuration: clock).dropFrame
        return CMXTimecode(nominalRate: nominal, dropFrame: drop).string(frames: frames)
    }

    // MARK: Reading

    /// The file's source timecode: tmcd, else rtmd (MP4/MOV), or bext (WAV/BWF). nil = the file carries none.
    public static func read(from url: URL) throws -> SourceTimecode? {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard let head = try fh.read(upToCount: 4), head.count == 4 else { return nil }
        let b = [UInt8](head)
        if b == [0x52, 0x49, 0x46, 0x46] || b == [0x52, 0x46, 0x36, 0x34] { return try readBext(fh) }      // RIFF / RF64
        return try readMP4(fh)
    }

    private static let maxMoov: UInt64 = 64 << 20

    private struct TrackSample { var format: String; var description: Data; var sample: Data }

    private static func readMP4(_ fh: FileHandle) throws -> SourceTimecode? {
        let end = try fh.seekToEnd()
        var pos: UInt64 = 0
        while pos + 8 <= end {
            try fh.seek(toOffset: pos)
            guard let h = try fh.read(upToCount: 8), h.count == 8 else { return nil }
            let hb = [UInt8](h)
            var size = UInt64(be32(hb, 0)), header: UInt64 = 8
            if size == 1 {
                guard let l = try fh.read(upToCount: 8), l.count == 8 else { return nil }
                size = [UInt8](l).reduce(0) { $0 << 8 | UInt64($1) }; header = 16
            } else if size == 0 { size = end - pos }
            guard size >= header, size <= end - pos else { return nil }
            if String(decoding: hb[4..<8], as: UTF8.self) == "moov" {
                guard size - header <= maxMoov else { return nil }
                try fh.seek(toOffset: pos + header)
                let moov = try fh.read(upToCount: Int(size - header)) ?? Data()
                return try fromMoov(moov, file: fh)
            }
            pos += size
        }
        return nil
    }

    /// tmcd and rtmd tracks of a `moov` body, preferring tmcd.
    private static func fromMoov(_ moov: Data, file fh: FileHandle) throws -> SourceTimecode? {
        var found: [String: TrackSample] = [:]
        for trak in boxes(moov, in: 0..<moov.count, named: "trak") {
            guard let t = try trackSample(moov, trak: trak, file: fh), found[t.format] == nil else { continue }
            found[t.format] = t
        }
        if let t = found["tmcd"], let tc = parseTmcd(description: t.description, sample: t.sample) { return tc }
        if let t = found["rtmd"], let tc = parseRTMD(sample: t.sample, clock: pictureClock(moov)) { return tc }
        return nil
    }

    /// Frame duration of the first video track (mdhd timescale, first stts delta).
    private static func pictureClock(_ d: Data) -> Time? {
        for trak in boxes(d, in: 0..<d.count, named: "trak") {
            guard let mdia = boxes(d, in: trak, named: "mdia").first,
                  let hdlr = boxes(d, in: mdia, named: "hdlr").first, hdlr.count >= 12,
                  String(decoding: d[(hdlr.lowerBound + 8)..<(hdlr.lowerBound + 12)], as: UTF8.self) == "vide",
                  let mdhd = boxes(d, in: mdia, named: "mdhd").first, mdhd.count >= 24,
                  let minf = boxes(d, in: mdia, named: "minf").first,
                  let stbl = boxes(d, in: minf, named: "stbl").first,
                  let stts = boxes(d, in: stbl, named: "stts").first, stts.count >= 16 else { continue }
            let at = d[mdhd.lowerBound] == 1 ? 20 : 12
            let scale = Int64(be32(d, mdhd.lowerBound + at)), delta = Int64(be32(d, stts.lowerBound + 12))
            if scale > 0, delta > 0 { return Time(delta, scale) }
        }
        return nil
    }

    private static func trackSample(_ d: Data, trak: Range<Int>, file fh: FileHandle) throws -> TrackSample? {
        guard let mdia = boxes(d, in: trak, named: "mdia").first,
              let minf = boxes(d, in: mdia, named: "minf").first,
              let stbl = boxes(d, in: minf, named: "stbl").first,
              let stsd = boxes(d, in: stbl, named: "stsd", skipFullBox: 8).first, stsd.count >= 16 else { return nil }
        let entry = stsd.lowerBound
        let size = Int(be32(d, entry))
        guard size >= 16, entry + size <= d.count else { return nil }
        let format = String(decoding: d[(entry + 4)..<(entry + 8)], as: UTF8.self)
        guard format == "tmcd" || format == "rtmd" else { return nil }
        var offset: UInt64?
        if let co = boxes(d, in: stbl, named: "stco", skipFullBox: 4).first, co.count >= 8, be32(d, co.lowerBound) > 0 {
            offset = UInt64(be32(d, co.lowerBound + 4))
        } else if let co = boxes(d, in: stbl, named: "co64", skipFullBox: 4).first, co.count >= 12, be32(d, co.lowerBound) > 0 {
            offset = UInt64(be32(d, co.lowerBound + 4)) << 32 | UInt64(be32(d, co.lowerBound + 8))
        }
        guard let offset else { return nil }
        var length = format == "tmcd" ? 4 : 4096
        if let sz = boxes(d, in: stbl, named: "stsz", skipFullBox: 4).first, sz.count >= 4 {
            let fixed = Int(be32(d, sz.lowerBound))
            let first = fixed != 0 ? fixed : (sz.count >= 12 ? Int(be32(d, sz.lowerBound + 8)) : 0)
            if first > 0 { length = min(first, 65_536) }
        }
        try fh.seek(toOffset: offset)
        guard let s = try fh.read(upToCount: length), !s.isEmpty else { return nil }
        return TrackSample(format: format, description: d.subdata(in: entry..<(entry + size)), sample: s)
    }

    /// `description`: the whole tmcd sample entry; `sample`: the first sample (a 32-bit frame counter).
    static func parseTmcd(description: Data, sample: Data) -> SourceTimecode? {
        // size(4) 'tmcd'(4) reserved(6) dataRef(2) | reserved(4) flags(4) timescale(4) frameDuration(4) frames(1) reserved(1)
        let b = [UInt8](description)
        guard b.count >= 34, sample.count >= 4 else { return nil }
        let flags = be32(b, 20), timescale = Int64(be32(b, 24)), duration = Int64(be32(b, 28))
        guard timescale > 0, duration > 0 else { return nil }
        let raw = be32([UInt8](sample), 0)
        let counter: Int64 = flags & 0x4 != 0 ? Int64(Int32(bitPattern: raw)) : Int64(raw)
        guard counter >= 0 else { return nil }
        // Frame counter times the track's own frame duration: 30000/1001 stays exact, not 30.
        let origin = Time(reducing: Int128(counter) * Int128(duration), Int128(timescale))
        return SourceTimecode(origin: origin, frameDuration: Time(duration, timescale), dropFrame: flags & 0x1 != 0, source: .tmcd)
    }

    /// Sony's rtmd sample: a 0x1c-byte header whose bytes 0x0d, 0x0e, 0x0f and 0x11 are read as hours, minutes, seconds and
    /// frame in BCD (layout after ExifTool's notes; unverified on camera files). Only digits that form a valid time are
    /// taken, so a header of another layout gives nil rather than a wrong timecode. `clock`: the picture's frame duration
    /// (the header does not carry it); nil = nothing is read.
    static func parseRTMD(sample: Data, clock: Time?) -> SourceTimecode? {
        let b = [UInt8](sample)
        guard let clock, clock > .zero, b.count >= 0x1c, Int(b[0]) << 8 | Int(b[1]) == 0x1c else { return nil }
        func bcd(_ v: UInt8) -> Int64? { let hi = Int64(v >> 4), lo = Int64(v & 0xF); return hi < 10 && lo < 10 ? hi * 10 + lo : nil }
        let nominal = Int64(CMXTimecode(frameDuration: clock, preferDrop: false).nominalRate)
        guard let h = bcd(b[0x0d]), let m = bcd(b[0x0e]), let s = bcd(b[0x0f]), let f = bcd(b[0x11]),
              h < 24, m < 60, s < 60, f < nominal else { return nil }
        let frames = (h * 3600 + m * 60 + s) * nominal + f
        return SourceTimecode(origin: Time(reducing: Int128(frames) * Int128(clock.value), Int128(clock.timescale)),
                              frameDuration: clock, dropFrame: false, source: .rtmd)
    }

    // MARK: bext

    private static func readBext(_ fh: FileHandle) throws -> SourceTimecode? {
        let end = try fh.seekToEnd()
        var pos: UInt64 = 12
        var sampleRate: Int64?
        var reference: UInt64?
        while pos + 8 <= end, sampleRate == nil || reference == nil {
            try fh.seek(toOffset: pos)
            guard let h = try fh.read(upToCount: 8), h.count == 8 else { break }
            let b = [UInt8](h)
            let id = String(decoding: b[0..<4], as: UTF8.self), size = UInt64(le32(b, 4))
            if id == "fmt ", size >= 8, let f = try fh.read(upToCount: 8), f.count == 8 {
                sampleRate = Int64(le32([UInt8](f), 4))
            } else if id == "bext", size >= 346, let body = try fh.read(upToCount: 346), body.count == 346 {
                let x = [UInt8](body)
                reference = UInt64(le32(x, 338)) | UInt64(le32(x, 342)) << 32
            }
            if id == "data", pos + 8 + size > end { break }
            pos += 8 + size + (size & 1)
        }
        guard let sampleRate, sampleRate > 0, let reference, reference <= UInt64(Int64.max) else { return nil }
        return SourceTimecode(origin: Time(Int64(reference), sampleRate), frameDuration: nil, dropFrame: false, source: .bext)
    }

    // MARK: Bytes

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[d.startIndex + i]) << 24 | UInt32(d[d.startIndex + i + 1]) << 16 | UInt32(d[d.startIndex + i + 2]) << 8 | UInt32(d[d.startIndex + i + 3])
    }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i + 3]) << 24 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i])
    }

    /// Body ranges of the child boxes called `name` inside `range`; `skipFullBox` bytes at the start of a body (version and
    /// flags, entry count) are skipped so the range starts at the payload.
    private static func boxes(_ d: Data, in range: Range<Int>, named name: String, skipFullBox: Int = 0) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let size = Int(be32(d, p))
            guard size >= 8, p + size <= range.upperBound else { break }
            let type = String(decoding: [d[p + 4], d[p + 5], d[p + 6], d[p + 7]], as: UTF8.self)
            if type == name, 8 + skipFullBox <= size { out.append((p + 8 + skipFullBox)..<(p + size)) }
            p += size
        }
        return out
    }
}
