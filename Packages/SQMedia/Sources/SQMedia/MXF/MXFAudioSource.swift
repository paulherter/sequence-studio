import Foundation
import SQCore
import Synchronization

/// PCM audio of an MXF file. Cameras write one mono track per channel (Sony XAVC: 4 or 8 tracks, 24 bit, 48 kHz);
/// every channel of every sound track is one source channel here, in track order. The engine's sources are stereo:
/// `left` and `right` say which source channels feed each side. Default: mono channels play centered, the first two
/// on both sides at -3 dB each (equal power, like two centered mono tracks; dual mono does not come out 6 dB hot).
/// A single microphone on channel 1 is then heard on both sides; a file with one channel plays at unity, like the
/// first audio track of a camera MOV (`AssetAudioSource`).
public final class MXFAudioSource: AudioSource, @unchecked Sendable {
    /// One source channel: sound track, channel inside that track's element.
    public struct Channel: Sendable, Hashable {
        public var track: UInt32
        public var indexInTrack: Int
        public var bits: Int
    }

    public let sampleRate: Int
    /// Sample rate of the file.
    public let nativeRate: Int
    public let channels: [Channel]
    public var channelCount: Int { channels.count }
    public let left: [Int], right: [Int]
    public let isMono: Bool
    /// Frames at `sampleRate`.
    public let totalFrames: Int64
    /// Frames at `nativeRate`.
    public let nativeTotal: Int64

    private struct Layout { var track: UInt32; var stride: Int; var bytes: Int; var bigEndian: Bool; var channels: Int }
    private let file: MXFFile
    private let layouts: [Layout]
    /// Channel -> (layout, channel in layout).
    private let map: [(layout: Int, channel: Int)]
    /// Samples per edit unit: one entry (constant), a repeating cadence (29.97 fps: 1602 1601 1602 1601 1602), or one per unit.
    private let cadence: [Int]
    private let cadenceSum: Int64
    private let eagerStarts: [Int64]?
    /// Irregular cadence in a long file: the per-unit table is not built while probing. It grows with the reads,
    /// each one walking only the units up to the one it needs (never the whole file at once).
    private let isLazy: Bool
    private let lazyStarts = Mutex<[Int64]>([0])
    private let firstTrack: UInt32
    private let firstStride: Int
    /// Units the lazy table has walked so far (tests).
    var walkedUnits: Int { lazyStarts.withLock { $0.count - 1 } }
    /// Units up to which an irregular cadence is resolved while opening.
    static let eagerUnitLimit = 4096

    private func samples(inUnit u: Int) -> Int64 {
        Int64(file.elements(ofUnit: u).first(where: { $0.track == firstTrack }).map { $0.range.count / firstStride } ?? 0)
    }

    private func lazyStart(ofUnit u: Int) -> Int64 {
        let u = min(max(0, u), file.unitCount)
        return lazyStarts.withLock { s in
            while s.count <= u { s.append(s[s.count - 1] + samples(inUnit: s.count - 1)) }
            return s[u]
        }
    }

    private func lazyUnit(containing sample: Int64) -> Int {
        let units = file.unitCount
        return lazyStarts.withLock { s in
            while s[s.count - 1] <= sample, s.count <= units { s.append(s[s.count - 1] + samples(inUnit: s.count - 1)) }
            var lo = 0, hi = s.count - 1
            while lo + 1 < hi { let mid = (lo + hi) / 2; if s[mid] <= sample { lo = mid } else { hi = mid } }
            return lo
        }
    }

    /// First sample of every edit unit (and the total as last entry), from the sound element sizes.
    private static func starts(_ file: MXFFile, track: UInt32, stride: Int) -> [Int64] {
        let units = file.unitCount
        var starts: [Int64] = [0]
        starts.reserveCapacity(units + 1)
        for u in 0..<units {
            let n = file.elements(ofUnit: u).first(where: { $0.track == track }).map { $0.range.count / stride } ?? 0
            starts.append(starts[u] + Int64(n))
        }
        return starts
    }
    /// Clip-wrapped sound (one element for the whole file): its bytes.
    private let clip: Range<Int>?

    private struct Cache { var blocks: [Int64: ([Float], [Float])] = [:]; var order: [Int64] = [] }
    private let cache = Mutex(Cache())
    private static let maxBlocks = 6
    private var blockFrames: Int { sampleRate }

    public static func open(url: URL, sampleRate: Int, left: [Int]? = nil, right: [Int]? = nil) async throws -> MXFAudioSource {
        try MXFAudioSource(file: try MXFFile.open(url), sampleRate: sampleRate, left: left, right: right)
    }

    public convenience init(file: MXFFile, sampleRate: Int, left: [Int]? = nil, right: [Int]? = nil) throws {
        try self.init(file: file, sampleRate: sampleRate, left: left, right: right, eagerUnits: Self.eagerUnitLimit)
    }

    init(file: MXFFile, sampleRate: Int, left: [Int]?, right: [Int]?, eagerUnits: Int) throws {
        self.file = file
        self.sampleRate = max(1, sampleRate)
        let tracks = file.soundTracks.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        guard !tracks.isEmpty else { throw MediaError.unreadable }
        var layouts: [Layout] = [], channels: [Channel] = [], map: [(Int, Int)] = []
        var rate = 0
        for t in tracks {
            guard let d = t.sound else { continue }
            guard d.isPCM else { throw MediaError.unsupportedCodec("\(d.codecName) audio in MXF") }
            // Element type 0x10 is SMPTE 331M (D-10) AES3 with channel status framing, not plain PCM.
            guard UInt8(truncatingIfNeeded: t.number >> 8) != 0x10 else { throw MediaError.unsupportedCodec("D-10 AES3 audio in MXF") }
            if rate == 0 { rate = d.sampleRate }
            guard d.sampleRate == rate else { continue }
            let bytes = d.bytesPerSample
            layouts.append(Layout(track: t.number, stride: d.blockAlign >= bytes * d.channels ? d.blockAlign : bytes * d.channels,
                                  bytes: bytes, bigEndian: d.isBigEndian, channels: d.channels))
            for c in 0..<d.channels {
                channels.append(Channel(track: t.number, indexInTrack: c, bits: d.bits)); map.append((layouts.count - 1, c))
            }
        }
        guard !layouts.isEmpty, rate > 0 else { throw MediaError.unreadable }
        self.layouts = layouts; self.channels = channels; self.map = map
        nativeRate = rate
        let n = channels.count
        let centered = n > 1 ? [0, 1] : [0]
        // A choice the file cannot play (a relink to a file with fewer channels) falls back to the file's layout:
        // never a dead side, never silence.
        let chosen = left == nil && right == nil ? nil
            : AudioChannelMap(left: left ?? [], right: right ?? [])?.fitting(channels: n)
        self.left = chosen?.left ?? centered
        self.right = chosen?.right ?? centered
        isMono = self.left == self.right

        // How many samples each edit unit holds, from the first sound element of each unit.
        let first = layouts[0]
        firstTrack = first.track; firstStride = first.stride
        func samples(inUnit u: Int) -> Int {
            guard let e = file.elements(ofUnit: u).first(where: { $0.track == first.track }) else { return 0 }
            return e.range.count / first.stride
        }
        let units = file.unitCount
        var clip: Range<Int>?
        if units == 1, let e = file.elements(ofUnit: 0).first(where: { $0.track == first.track }), file.videoTrack == nil {
            clip = e.range                       // audio-only, clip-wrapped: one element holds everything
        }
        self.clip = clip
        let head = (0..<min(units, 10)).map(samples(inUnit:))
        if let clip {
            cadence = [clip.count / first.stride]; eagerStarts = nil; isLazy = false
        } else if units >= 10, head[0..<5].elementsEqual(head[5..<10]) {
            cadence = Set(head).count == 1 ? [head[0]] : Array(head[0..<5]); eagerStarts = nil; isLazy = false
        } else if units <= eagerUnits {
            cadence = []; eagerStarts = Self.starts(file, track: first.track, stride: first.stride); isLazy = false
        } else {
            // Walking every unit of an hour-long clip does not belong in a probe: the length comes from the edit
            // rate now, the exact table when sound is first read.
            cadence = []; eagerStarts = nil; isLazy = true
        }
        cadenceSum = cadence.reduce(0) { $0 + Int64($1) }
        if let eagerStarts { nativeTotal = eagerStarts.last ?? 0 }
        else if isLazy {
            // A corrupt edit rate or sample rate must not overflow.
            let t = file.videoTrack ?? tracks[0]
            let a = Int64(units).multipliedReportingOverflow(by: Int64(rate))
            let b = a.partialValue.multipliedReportingOverflow(by: Int64(t.editRateDen))
            guard t.editRateNum > 0, t.editRateDen > 0, !a.overflow, !b.overflow else { throw MediaError.unreadable }
            nativeTotal = b.partialValue / Int64(t.editRateNum)
        } else if clip != nil { nativeTotal = cadenceSum }
        else {
            let full = Int64(units / cadence.count), rest = units % cadence.count
            nativeTotal = full * cadenceSum + cadence[0..<rest].reduce(0) { $0 + Int64($1) }
        }
        guard nativeTotal > 0 else { throw MediaError.unreadable }
        let scaled = nativeTotal.multipliedReportingOverflow(by: Int64(self.sampleRate))
        guard !scaled.overflow else { throw MediaError.unreadable }
        totalFrames = scaled.partialValue / Int64(rate)
    }

    // MARK: sample positions

    private func start(ofUnit u: Int) -> Int64 {
        if isLazy { return lazyStart(ofUnit: u) }
        if let unitStarts = eagerStarts { return unitStarts[min(max(0, u), unitStarts.count - 1)] }
        let full = Int64(u / cadence.count), rest = u % cadence.count
        return full * cadenceSum + cadence[0..<rest].reduce(0) { $0 + Int64($1) }
    }

    private func unit(containing s: Int64) -> Int {
        if isLazy { return lazyUnit(containing: s) }
        if let unitStarts = eagerStarts {
            var lo = 0, hi = unitStarts.count - 1
            while lo + 1 < hi { let mid = (lo + hi) / 2; if unitStarts[mid] <= s { lo = mid } else { hi = mid } }
            return lo
        }
        guard cadenceSum > 0 else { return 0 }
        var u = Int(s / cadenceSum) * cadence.count
        var at = (s / cadenceSum) * cadenceSum
        for c in cadence { if at + Int64(c) > s { break }; at += Int64(c); u += 1 }
        return u
    }

    /// Native-rate samples `range` of the given source channels; silence where the file has nothing.
    func decode(_ wanted: [Int], range: Range<Int64>) -> [[Float]] {
        let count = Int(range.count)
        var out = [[Float]](repeating: [Float](repeating: 0, count: count), count: wanted.count)
        let lo = max(0, range.lowerBound), hi = min(nativeTotal, range.upperBound)
        guard lo < hi else { return out }
        func copy(_ element: Range<Int>, layout li: Int, elementStart: Int64) {
            let l = layouts[li]
            let have = Int64(element.count / l.stride)
            let a = max(lo, elementStart), b = min(hi, elementStart + have)
            guard a < b else { return }
            let bytes = (element.lowerBound + Int(a - elementStart) * l.stride)..<(element.lowerBound + Int(b - elementStart) * l.stride)
            _ = file.bytes.withBytes(bytes) { p in
                for (slot, c) in wanted.enumerated() where map[c].layout == li {
                    let offset = map[c].channel * l.bytes
                    out[slot].withUnsafeMutableBufferPointer { dst in
                        Self.convert(p, stride: l.stride, offset: offset, bytes: l.bytes, bigEndian: l.bigEndian,
                                     into: dst.baseAddress! + Int(a - range.lowerBound), count: Int(b - a))
                    }
                }
            }
        }
        if let clip {
            for li in layouts.indices.prefix(1) { copy(clip, layout: li, elementStart: 0) }
            return out
        }
        var u = unit(containing: lo)
        while u < file.unitCount {
            let s = start(ofUnit: u)
            if s >= hi { break }
            let elements = file.elements(ofUnit: u)
            for (li, l) in layouts.enumerated() where wanted.contains(where: { map[$0].layout == li }) {
                if let e = elements.first(where: { $0.track == l.track }) { copy(e.range, layout: li, elementStart: s) }
            }
            u += 1
        }
        return out
    }

    /// Signed integer PCM (1 to 4 bytes) to Float in -1...1.
    static func convert(_ p: UnsafeBufferPointer<UInt8>, stride: Int, offset: Int, bytes: Int, bigEndian: Bool,
                        into dst: UnsafeMutablePointer<Float>, count: Int) {
        let scale = 1 / Float(Int64(1) << Int64(8 * bytes - 1))
        let shift = Int32(32 - 8 * bytes)
        for i in 0..<count {
            let o = i * stride + offset
            guard o + bytes <= p.count else { break }
            var v: UInt32 = 0
            if bigEndian { for k in 0..<bytes { v = v << 8 | UInt32(p[o + k]) } }
            else { for k in (0..<bytes).reversed() { v = v << 8 | UInt32(p[o + k]) } }
            dst[i] = Float(Int32(bitPattern: v << UInt32(shift)) >> shift) * scale
        }
    }

    // MARK: output

    /// Output-rate frames `range` of source channels `wanted` (linear interpolation when the rates differ).
    private func render(_ wanted: [Int], range: Range<Int64>) -> [[Float]] {
        if nativeRate == sampleRate { return decode(wanted, range: range) }
        let n = Int(range.count)
        let num = Int64(nativeRate), den = Int64(sampleRate)
        let first = range.lowerBound * num / den
        let last = (range.upperBound - 1) * num / den + 2
        let src = decode(wanted, range: first..<last)
        return src.map { s in
            var o = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let pos = (range.lowerBound + Int64(i)) * num
                let k = Int(pos / den - first)
                let f = Float(pos % den) / Float(den)
                o[i] = s[k] + (s[k + 1] - s[k]) * f
            }
            return o
        }
    }

    private func mix(_ list: [Int], _ decoded: [[Float]], _ wanted: [Int], count: Int) -> [Float] {
        var o = [Float](repeating: 0, count: count)
        // Several mono channels summed to the center: -3 dB each (equal power). Channels routed to one side only
        // and a single channel stay at unity.
        let gain: Float = isMono && list.count > 1 ? Float(0.5).squareRoot() : 1
        for c in list {
            guard let slot = wanted.firstIndex(of: c) else { continue }
            if list.count == 1 { return decoded[slot] }
            for i in 0..<count { o[i] += decoded[slot][i] * gain }
        }
        return o
    }

    private func block(_ b: Int64) -> ([Float], [Float]) {
        if let hit = cache.withLock({ $0.blocks[b] }) { return hit }
        let range = (b * Int64(blockFrames))..<min(totalFrames, (b + 1) * Int64(blockFrames))
        let wanted = Array(Set(left + right)).sorted()
        let decoded = render(wanted, range: range)
        let l = mix(left, decoded, wanted, count: Int(range.count))
        let r = isMono ? l : mix(right, decoded, wanted, count: Int(range.count))
        cache.withLock { c in
            c.blocks[b] = (l, r); c.order.append(b)
            while c.order.count > Self.maxBlocks { c.blocks[c.order.removeFirst()] = nil }
        }
        return (l, r)
    }

    public func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        guard sourceFrame >= 0, sourceFrame < totalFrames, count > 0 else { return 0 }
        let n = Int(min(Int64(count), totalFrames - sourceFrame))
        var done = 0
        while done < n {
            let at = sourceFrame + Int64(done)
            let b = at / Int64(blockFrames)
            let (l, r) = block(b)
            let src = channel == 0 ? l : r
            let o = Int(at - b * Int64(blockFrames))
            let take = min(n - done, src.count - o)
            guard take > 0 else { break }
            src.withUnsafeBufferPointer { (buffer + done).update(from: $0.baseAddress! + o, count: take) }
            done += take
        }
        return done
    }

    /// One source channel on its own (for channel routing), at the output rate. Returns the frames written.
    public func read(sourceChannel c: Int, from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>) -> Int {
        guard c >= 0, c < channels.count, sourceFrame >= 0, sourceFrame < totalFrames, count > 0 else { return 0 }
        let n = Int(min(Int64(count), totalFrames - sourceFrame))
        let d = render([c], range: sourceFrame..<(sourceFrame + Int64(n)))[0]
        d.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: n) }
        return n
    }

    /// The whole file in order, block by block (waveforms, analysis).
    public func streamAll(isCancelled: () -> Bool = { false }, _ body: (UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void) throws {
        let wanted = Array(Set(left + right)).sorted()
        var at: Int64 = 0
        while at < totalFrames {
            if isCancelled() { throw CancellationError() }
            let range = at..<min(totalFrames, at + Int64(blockFrames))
            let decoded = render(wanted, range: range)
            let l = mix(left, decoded, wanted, count: Int(range.count))
            let r = isMono ? l : mix(right, decoded, wanted, count: Int(range.count))
            try l.withUnsafeBufferPointer { lp in try r.withUnsafeBufferPointer { rp in try body(lp.baseAddress!, rp.baseAddress!, l.count) } }
            at = range.upperBound
        }
    }
}
