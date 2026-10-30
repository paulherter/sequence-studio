import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// One packet-to-PCM codec of a WebM audio track (native sample rate, one array per channel).
protocol WebMPacketDecoder: AnyObject {
    var channels: Int { get }
    var sampleRate: Int { get }
    /// Packets to feed before the wanted one after a seek, so the decoder state is warm.
    var prerollPackets: Int { get }
    func decode(_ packet: Data) -> [[Float]]
    func reset()
}

extension VorbisDecoder: WebMPacketDecoder {
    var prerollPackets: Int { 1 }
}

/// Opus through the system decoder (AudioToolbox). Mono or stereo (channel mapping family 0).
final class OpusPacketDecoder: WebMPacketDecoder {
    let channels: Int
    let sampleRate = 48_000
    let prerollPackets = 4
    private let inFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    private var converter: AVAudioConverter
    /// The system decoder trims its own priming (120 samples) from the first packet after creation or reset.
    private var fresh = true

    init(channels: Int) throws {
        guard channels == 1 || channels == 2 else { throw MediaError.unsupportedCodec("Opus \(channels)-channel") }
        self.channels = channels
        var d = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                            mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                            mBitsPerChannel: 0, mReserved: 0)
        guard let inF = AVAudioFormat(streamDescription: &d),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: false),
              let c = AVAudioConverter(from: inF, to: pcm) else { throw MediaError.unsupportedCodec("Opus") }
        inFormat = inF; pcmFormat = pcm; converter = c
    }

    func reset() { converter.reset(); fresh = true }

    func decode(_ packet: Data) -> [[Float]] {
        guard !packet.isEmpty,
              let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5760) else { return Array(repeating: [], count: channels) }
        let cb = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { cb.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        cb.packetCount = 1; cb.byteLength = UInt32(packet.count)
        cb.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        var given = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return cb
        }
        let n = Int(out.frameLength)
        guard err == nil, n > 0, let data = out.floatChannelData else { return Array(repeating: [], count: channels) }
        // Give back the packet's full length: the trimmed head is restored as silence, so every sample sits at its
        // stream position (pre-skip alignment is sample-exact, also after a seek).
        let expected = Self.samples(in: packet) ?? n
        let lead = fresh && n < expected ? expected - n : 0
        fresh = false
        return (0..<channels).map { [Float](repeating: 0, count: lead) + Array(UnsafeBufferPointer(start: data[$0], count: n)) }
    }

    /// Samples at 48 kHz in an Opus packet (RFC 6716 section 3.1), nil when malformed.
    static func samples(in p: Data) -> Int? {
        guard let toc = p.first else { return nil }
        let config = Int(toc >> 3)
        let frameSize: Int      // in 48 kHz samples
        switch config {
        case 0...11: frameSize = [480, 960, 1920, 2880][config & 3]
        case 12...15: frameSize = (config & 1) == 0 ? 480 : 960
        default: frameSize = [120, 240, 480, 960][config & 3]
        }
        switch toc & 3 {
        case 0: return frameSize
        case 1, 2: return frameSize * 2
        default:
            guard p.count > 1 else { return nil }
            return frameSize * Int(p[p.startIndex + 1] & 0x3F)
        }
    }
}

/// Uncompressed PCM packets (Matroska A_PCM/INT/LIT, A_PCM/FLOAT/IEEE) to float, one array per channel.
final class PCMPacketDecoder: WebMPacketDecoder {
    let channels: Int, sampleRate: Int, bytesPerSample: Int, isFloat: Bool
    let prerollPackets = 0
    init(channels: Int, sampleRate: Int, bitDepth: Int, isFloat: Bool) throws {
        let ok = isFloat ? bitDepth == 32 : [16, 24, 32].contains(bitDepth)
        guard (1...2).contains(channels), ok, sampleRate > 0 else { throw MediaError.unsupportedCodec("PCM") }
        self.channels = channels; self.sampleRate = sampleRate; self.isFloat = isFloat; bytesPerSample = bitDepth / 8
    }
    func reset() {}
    func decode(_ packet: Data) -> [[Float]] {
        let frame = channels * bytesPerSample, n = packet.count / frame
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: channels)
        let b = [UInt8](packet)
        for i in 0..<n {
            for c in 0..<channels {
                let o = i * frame + c * bytesPerSample
                switch (isFloat, bytesPerSample) {
                case (true, _): out[c][i] = Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
                case (_, 2): out[c][i] = Float(Int16(bitPattern: UInt16(b[o]) | UInt16(b[o + 1]) << 8)) / 32768
                case (_, 3): out[c][i] = Float(Int32(bitPattern: UInt32(b[o]) << 8 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 24) >> 8) / 8_388_608
                default: out[c][i] = Float(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)) / 2_147_483_648
                }
            }
        }
        return out
    }
}

/// AAC-LC through the system decoder (AudioToolbox). `config` is the AudioSpecificConfig of the track's codec private data.
final class AACPacketDecoder: WebMPacketDecoder {
    let channels: Int, sampleRate: Int
    let prerollPackets = 2
    static let framesPerPacket = 1024
    private let inFormat: AVAudioFormat, pcmFormat: AVAudioFormat
    private var converter: AVAudioConverter

    /// Sample rate and channel count from an AudioSpecificConfig; nil for anything but plain AAC-LC mono / stereo (no
    /// SBR / PS, which double the output rate) or when the data is too short.
    static func parse(config c: Data) -> (rate: Int, channels: Int)? {
        guard c.count >= 2, c.count <= maxConfigSize else { return nil }
        let b = [UInt8](c)
        var r = BitReader(b)
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard let type = r.read(5), let freqIndex = r.read(4), type == 2, freqIndex < rates.count,
              let chan = r.read(4) else { return nil }
        if (1...2).contains(chan) { return (rates[freqIndex], chan) }
        // Channel configuration 0: the layout is in a program config element after the three GASpecificConfig flags.
        guard chan == 0, r.skip(1), let core = r.read(1), core == 0 || r.skip(14), r.skip(1),
              let n = pceChannels(&r), (1...2).contains(n) else { return nil }
        return (rates[freqIndex], n)
    }

    /// Channel count of a program config element (ISO 14496-3 table 4.2); nil when the data ends early.
    static func pceChannels(_ r: inout BitReader) -> Int? {
        guard r.skip(4 + 2 + 4), let front = r.read(4), let side = r.read(4), let back = r.read(4), let lfe = r.read(2),
              r.skip(3 + 4), let mono = r.read(1) else { return nil }
        if mono == 1 { guard r.skip(4) else { return nil } }
        guard let stereo = r.read(1) else { return nil }
        if stereo == 1 { guard r.skip(4) else { return nil } }
        guard let matrix = r.read(1) else { return nil }
        if matrix == 1 { guard r.skip(3) else { return nil } }
        var channels = lfe
        for _ in 0..<(front + side + back) {
            guard let cpe = r.read(1), r.skip(4) else { return nil }
            channels += cpe == 1 ? 2 : 1
        }
        return channels
    }

    /// MSB-first bit reader that returns nil instead of reading past the end.
    struct BitReader {
        let bytes: [UInt8]
        var pos = 0
        init(_ b: [UInt8]) { bytes = b }
        mutating func read(_ n: Int) -> Int? {
            guard pos + n <= bytes.count * 8 else { return nil }
            var v = 0
            for _ in 0..<n { v = v << 1 | Int(bytes[pos >> 3] >> UInt8(7 - pos & 7)) & 1; pos += 1 }
            return v
        }
        mutating func skip(_ n: Int) -> Bool { read(n) != nil }
    }

    /// MPEG-4 `esds` payload wrapping the AudioSpecificConfig (what Core Audio takes as the AAC magic cookie).
    static func esds(config c: Data) -> Data {
        let asc = [UInt8](c)
        let dsi: [UInt8] = [0x05] + descriptorLength(asc.count) + asc
        let dcdBody: [UInt8] = [0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + dsi
        let dcd: [UInt8] = [0x04] + descriptorLength(dcdBody.count) + dcdBody
        let sl: [UInt8] = [0x06, 0x01, 0x02]
        let esBody: [UInt8] = [0, 0, 0] + dcd + sl
        return Data([0, 0, 0, 0]) + Data([0x03] + descriptorLength(esBody.count) + esBody)
    }

    /// MPEG-4 descriptor size: 7 bits per byte, high bit set on all but the last byte.
    static func descriptorLength(_ n: Int) -> [UInt8] {
        var groups: [UInt8] = [UInt8(n & 0x7F)]
        var rest = n >> 7
        while rest > 0 { groups.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
        return groups
    }

    /// Longest AudioSpecificConfig accepted: plain AAC-LC ones are 2 bytes; a program config element with a comment
    /// field (up to 255 bytes) and extensions stay far below this.
    static let maxConfigSize = 4096

    init(config: Data) throws {
        guard let p = Self.parse(config: config) else { throw MediaError.unsupportedCodec("AAC (not AAC-LC)") }
        channels = p.channels; sampleRate = p.rate
        var d = AudioStreamBasicDescription(mSampleRate: Double(p.rate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2,
                                            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0,
                                            mChannelsPerFrame: UInt32(p.channels), mBitsPerChannel: 0, mReserved: 0)
        let cookie = Self.esds(config: config)
        var fd: CMAudioFormatDescription?
        let st = cookie.withUnsafeBytes {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &d, layoutSize: 0, layout: nil, magicCookieSize: cookie.count,
                                           magicCookie: $0.baseAddress, extensions: nil, formatDescriptionOut: &fd)
        }
        guard st == noErr, let fd else { throw MediaError.unsupportedCodec("AAC") }
        let inF = AVAudioFormat(cmAudioFormatDescription: fd)
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(p.rate), channels: AVAudioChannelCount(p.channels), interleaved: false),
              let conv = AVAudioConverter(from: inF, to: pcm) else { throw MediaError.unsupportedCodec("AAC") }
        inFormat = inF; pcmFormat = pcm; converter = conv
    }

    func reset() { converter.reset() }

    func decode(_ packet: Data) -> [[Float]] {
        guard !packet.isEmpty,
              let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(Self.framesPerPacket)) else {
            return [[Float]](repeating: [], count: channels)
        }
        let cb = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { cb.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        cb.packetCount = 1; cb.byteLength = UInt32(packet.count)
        cb.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        var given = false
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return cb
        }
        let n = Int(out.frameLength)
        guard err == nil, n > 0, let data = out.floatChannelData else { return [[Float]](repeating: [], count: channels) }
        return (0..<channels).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
    }
}

/// Audio of a WebM / Matroska file (Opus, Vorbis, AAC-LC or PCM) as timeline-rate stereo PCM, decoded block by block like `AssetAudioSource`.
/// AVFoundation cannot read these files, so packets are located by `WebMFile` and decoded here.
public final class WebMAudioSource: AudioSource, @unchecked Sendable {
    public let sampleRate: Int
    public let isMono: Bool
    /// Length of the audio in output frames.
    public let totalFrames: Int64

    private let file: WebMFile
    private let packets: [WebMBlock]
    /// Output (native rate) frame of the first sample of each packet, pre-skip already removed (may be negative).
    private let packetStart: [Int64]
    private let nativeRate: Int
    private let nativeTotal: Int64
    private let preSkip: Int64
    private let codec: Codec
    private let lock = Mutex(State())

    private enum Codec { case opus(channels: Int), vorbis(Data), aac(Data), pcm(channels: Int, rate: Int, bits: Int, float: Bool) }

    private struct Run {
        var decoder: any WebMPacketDecoder
        var resampler: AVAudioConverter?
        var nextPacket: Int
        /// Native-rate position of the next sample the decoder outputs.
        var discardBelow: Int64
        /// Output-rate frame of `left[0]`.
        var base: Int64
        var left: [Float] = [], right: [Float] = []
        var ended = false
        /// Source frames already handed to the resampler (to map output position).
        var started = false
    }
    private struct State {
        var run: Run?
        var blocks: [Int64: ([Float], [Float])] = [:]
        var order: [Int64] = []
    }
    private static let maxBlocks = 6

    /// Throws `MediaError.unreadable` without audio track, `unsupportedCodec` for codecs other than Opus, Vorbis, AAC-LC and PCM.
    public static func open(url: URL, sampleRate: Int) async throws -> WebMAudioSource {
        try WebMAudioSource(file: WebMFile.open(url), sampleRate: sampleRate)
    }

    public init(file: WebMFile, sampleRate: Int) throws {
        guard let t = file.track(.audio) else { throw MediaError.unreadable }
        guard !t.hasContentEncoding else { throw MediaError.unsupportedCodec("compressed " + WebMDemuxer.codecName(t.codecID)) }
        let blocks = file.blocks(of: t.number)
        guard !blocks.isEmpty else { throw MediaError.unreadable }
        self.file = file; self.sampleRate = sampleRate
        packets = blocks
        var starts: [Int64] = []
        starts.reserveCapacity(blocks.count)
        switch t.codecID {
        case "A_OPUS":
            let ch = max(1, t.channels)
            codec = .opus(channels: ch)
            nativeRate = 48_000
            var skip = t.codecDelayNs * 48_000 / 1_000_000_000
            if t.codecPrivate.count >= 12, t.codecPrivate.prefix(8).elementsEqual("OpusHead".utf8) {
                skip = Int64(t.codecPrivate[t.codecPrivate.startIndex + 10]) | Int64(t.codecPrivate[t.codecPrivate.startIndex + 11]) << 8
            }
            preSkip = skip
            var pos: Int64 = -skip
            for b in blocks { starts.append(pos); pos += Int64(OpusPacketDecoder.samples(in: file.payload(b)) ?? 0) }
            nativeTotal = pos
            isMono = ch == 1
            _ = try OpusPacketDecoder(channels: ch)   // fail early when the system has no decoder
        case "A_VORBIS":
            let probe = try Self.vorbis(t.codecPrivate)
            codec = .vorbis(t.codecPrivate)
            nativeRate = probe.sampleRate
            preSkip = 0
            var pos: Int64 = 0
            var prevN = 0
            for b in blocks {
                starts.append(pos)
                guard let n = probe.blockSize(of: file.payload(b)) else { continue }
                if prevN > 0 { pos += Int64(prevN / 4 + n / 4) }
                prevN = n
            }
            nativeTotal = pos
            isMono = probe.channels == 1
        case "A_AAC":
            let dec = try AACPacketDecoder(config: t.codecPrivate)
            codec = .aac(t.codecPrivate)
            nativeRate = dec.sampleRate
            // Encoder delay: Matroska CodecDelay when the file has one, else the standard 1024 samples.
            let skip = t.codecDelayNs > 0 ? t.codecDelayNs * Int64(dec.sampleRate) / 1_000_000_000 : Int64(AACPacketDecoder.framesPerPacket)
            preSkip = skip
            for i in blocks.indices { starts.append(Int64(i * AACPacketDecoder.framesPerPacket) - skip) }
            nativeTotal = max(0, Int64(blocks.count * AACPacketDecoder.framesPerPacket) - skip)
            isMono = dec.channels == 1
        case "A_PCM/INT/LIT", "A_PCM/FLOAT/IEEE":
            let isFloat = t.codecID == "A_PCM/FLOAT/IEEE"
            let rate = Int(t.sampleRate.rounded()), ch = max(1, t.channels)
            let bits = t.bitDepth > 0 ? t.bitDepth : (isFloat ? 32 : 16)
            let dec = try PCMPacketDecoder(channels: ch, sampleRate: rate, bitDepth: bits, isFloat: isFloat)
            codec = .pcm(channels: ch, rate: rate, bits: bits, float: isFloat)
            nativeRate = rate
            preSkip = 0
            var pos: Int64 = 0
            for b in blocks { starts.append(pos); pos += Int64(Int(b.size) / (ch * dec.bytesPerSample)) }
            nativeTotal = pos
            isMono = ch == 1
        default:
            throw MediaError.unsupportedCodec(WebMDemuxer.codecName(t.codecID))
        }
        packetStart = starts
        totalFrames = nativeTotal * Int64(sampleRate) / Int64(nativeRate)
    }

    private static func vorbis(_ priv: Data) throws -> VorbisDecoder {
        do { return try VorbisDecoder(codecPrivate: priv) } catch { throw MediaError.unsupportedCodec("Vorbis") }
    }

    private func makeDecoder() throws -> any WebMPacketDecoder {
        switch codec {
        case .opus(let ch): return try OpusPacketDecoder(channels: ch)
        case .vorbis(let priv): return try Self.vorbis(priv)
        case .aac(let config): return try AACPacketDecoder(config: config)
        case .pcm(let ch, let rate, let bits, let isFloat): return try PCMPacketDecoder(channels: ch, sampleRate: rate, bitDepth: bits, isFloat: isFloat)
        }
    }

    // MARK: AudioSource

    public func read(from sourceFrame: Int64, count: Int, into buffer: UnsafeMutablePointer<Float>, channel: Int) throws -> Int {
        guard sourceFrame >= 0, count > 0, channel == 0 || channel == 1, sourceFrame < totalFrames else { return 0 }
        let bs = Int64(sampleRate)
        return try lock.withLock { st in
            var done = 0
            while done < count {
                let f = sourceFrame + Int64(done)
                let b = f / bs
                guard f < totalFrames, let blk = try ensure(block: b, &st) else { break }
                let inBlock = Int(f - b * bs)
                let valid = Int(min(bs, totalFrames - b * bs))
                let n = min(count - done, valid - inBlock, blk.0.count - inBlock)
                if n <= 0 { break }
                let data = channel == 0 ? blk.0 : blk.1
                data.withUnsafeBufferPointer { buffer.advanced(by: done).update(from: $0.baseAddress! + inBlock, count: n) }
                done += n
            }
            return done
        }
    }

    /// Every output frame from the start to `totalFrames`, in order, a decoded chunk at a time (left, right, frame count;
    /// right == left for mono). The same samples `read` gives, without its one-second block cache and seek logic: the
    /// waveform's whole-file read. Independent of the cache `read` uses.
    func streamAll(isCancelled: () -> Bool = { false },
                   _ body: (UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void) throws {
        var run = try startRun(at: 0)
        var emitted: Int64 = run.base
        while emitted < totalFrames {
            if isCancelled() { throw CancellationError() }
            if run.left.isEmpty {
                if run.ended { break }
                try pump(&run)
                continue
            }
            let n = Int(min(Int64(run.left.count), totalFrames - emitted))
            try run.left.withUnsafeBufferPointer { l in
                try run.right.withUnsafeBufferPointer { r in try body(l.baseAddress!, r.baseAddress!, n) }
            }
            emitted += Int64(n)
            run.left.removeAll(keepingCapacity: true)
            run.right.removeAll(keepingCapacity: true)
        }
    }

    // MARK: decoding (lock held)

    private func store(_ b: Int64, _ l: [Float], _ r: [Float], _ st: inout State) {
        if st.blocks[b] == nil { st.order.append(b) }
        st.blocks[b] = (l, r)
        while st.order.count > Self.maxBlocks { st.blocks[st.order.removeFirst()] = nil }
    }

    private func ensure(block b: Int64, _ st: inout State) throws -> ([Float], [Float])? {
        if let blk = st.blocks[b] { return blk }
        let bs = Int64(sampleRate)
        let start = b * bs
        let needRestart: Bool
        if let run = st.run { needRestart = start < run.base || start > run.base + Int64(run.left.count) + 4 * bs || run.ended && run.left.count == 0 }
        else { needRestart = true }
        if needRestart { st.run = try startRun(at: start) }
        while true {
            guard var run = st.run else { return nil }
            if run.base > start { st.run = try startRun(at: start); continue }
            let need = min(bs, totalFrames - start)
            let have = Int64(run.left.count)
            if run.base + have >= start + need || run.ended && run.base + have > start {
                let off = Int(start - run.base)
                let end = min(run.left.count, off + Int(need))
                store(b, Array(run.left[off..<end]), Array(run.right[off..<end]), &st)
                run.left.removeFirst(end); run.right.removeFirst(end); run.base += Int64(end)
                st.run = run
                return st.blocks[b]
            }
            if run.ended { st.run = run; return nil }
            // Frames before the wanted block are not needed.
            if run.base < start {
                let drop = min(run.left.count, Int(start - run.base))
                run.left.removeFirst(drop); run.right.removeFirst(drop); run.base += Int64(drop)
            }
            try pump(&run)
            st.run = run
        }
    }

    private func startRun(at outFrame: Int64) throws -> Run {
        let native = outFrame * Int64(nativeRate) / Int64(sampleRate)
        // Packet that contains native frame `native`.
        var lo = 0, hi = packets.count
        while lo < hi { let m = (lo + hi) / 2; if packetStart[m] > native { hi = m } else { lo = m + 1 } }
        let wanted = max(0, lo - 1)
        let dec = try makeDecoder()
        let first = max(0, wanted - dec.prerollPackets)
        let startNative = max(0, packetStart[wanted])
        var resampler: AVAudioConverter?
        if nativeRate != sampleRate {
            let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(nativeRate), channels: 2, interleaved: false)!
            let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 2, interleaved: false)!
            resampler = AVAudioConverter(from: inF, to: outF)
            resampler?.primeMethod = .none
        }
        return Run(decoder: dec, resampler: resampler, nextPacket: first, discardBelow: startNative,
                   base: startNative * Int64(sampleRate) / Int64(nativeRate))
    }

    /// Decodes a few packets and appends the stereo, output-rate result to the run's buffer.
    private func pump(_ run: inout Run) throws {
        var l: [Float] = [], r: [Float] = []
        var produced = 0
        while run.nextPacket < packets.count && produced < nativeRate / 4 {
            let i = run.nextPacket
            let pcm = run.decoder.decode(file.payload(packets[i]))
            run.nextPacket += 1
            guard let n = pcm.first?.count, n > 0 else { continue }
            // Position of this packet's first output sample: its start (Vorbis: the previous packet's overlap lands here).
            let at = packetStart[i]
            let (pl, pr) = Self.stereo(pcm, vorbisOrder: { if case .vorbis = codec { return true } else { return false } }())
            // Drop samples before the wanted start (preroll) and before the stream start (pre-skip).
            let lower = max(run.discardBelow, 0)
            var from = 0
            if at < lower { from = Int(min(Int64(n), lower - at)) }
            if from < n { l.append(contentsOf: pl[from...]); r.append(contentsOf: pr[from...]); produced += n - from }
        }
        if run.nextPacket >= packets.count { run.ended = true }
        guard !l.isEmpty else { return }
        if let rs = run.resampler {
            let (rl, rr) = Self.resample(rs, l, r, flush: run.ended, inRate: nativeRate, outRate: sampleRate)
            run.left.append(contentsOf: rl); run.right.append(contentsOf: rr)
        } else {
            run.left.append(contentsOf: l); run.right.append(contentsOf: r)
        }
    }

    static func resample(_ c: AVAudioConverter, _ l: [Float], _ r: [Float], flush: Bool, inRate: Int, outRate: Int) -> ([Float], [Float]) {
        let inF = c.inputFormat, outF = c.outputFormat
        guard let src = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(l.count)) else { return ([], []) }
        src.frameLength = AVAudioFrameCount(l.count)
        l.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: l.count) }
        r.withUnsafeBufferPointer { src.floatChannelData![1].update(from: $0.baseAddress!, count: r.count) }
        let cap = AVAudioFrameCount(l.count * outRate / inRate + 64)
        guard let dst = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { return ([], []) }
        var given = false
        var err: NSError?
        _ = c.convert(to: dst, error: &err) { _, status in
            if given { status.pointee = flush ? .endOfStream : .noDataNow; return nil }
            given = true; status.pointee = .haveData; return src
        }
        let n = Int(dst.frameLength)
        guard err == nil, n > 0, let d = dst.floatChannelData else { return ([], []) }
        return (Array(UnsafeBufferPointer(start: d[0], count: n)), Array(UnsafeBufferPointer(start: d[1], count: n)))
    }

    /// Down/up-mix to stereo. Vorbis channel order: L, C, R, SL, SR, LFE (for 3...6 channels); Opus family 0 has 1 or 2.
    static func stereo(_ pcm: [[Float]], vorbisOrder: Bool) -> ([Float], [Float]) {
        switch pcm.count {
        case 0: return ([], [])
        case 1: return (pcm[0], pcm[0])
        case 2: return (pcm[0], pcm[1])
        default:
            let n = pcm[0].count
            var l = pcm[0], r = pcm[1]
            let k: Float = 0.7071
            if pcm.count == 3 {      // L C R
                for i in 0..<n { l[i] = pcm[0][i] + k * pcm[1][i]; r[i] = pcm[2][i] + k * pcm[1][i] }
            } else if pcm.count == 4 {   // L R SL SR
                for i in 0..<n { l[i] = pcm[0][i] + k * pcm[2][i]; r[i] = pcm[1][i] + k * pcm[3][i] }
            } else if pcm.count >= 6 {   // L C R SL SR LFE
                for i in 0..<n {
                    l[i] = (pcm[0][i] + k * pcm[1][i] + k * pcm[3][i]) * 0.6
                    r[i] = (pcm[2][i] + k * pcm[1][i] + k * pcm[4][i]) * 0.6
                }
            } else {
                for i in 0..<n { l[i] = pcm[0][i]; r[i] = pcm[1][i] }
            }
            return (l, r)
        }
    }
}
