import Accelerate
import Compression
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SQCore

/// QuickTime Animation ('rle ', 32 / 24 / 16 bit) frame parser. A chunk is: size (4), header (2; bit 3 = partial frame,
/// then start line (2), 2 reserved, line count (2), 2 reserved), then per line a skip byte (pixels to skip + 1) followed by
/// codes: 0 = another skip byte, 1...127 = that many literal pixels, -1 = end of line, -2...-127 = one pixel repeated.
/// Pixels are A R G B (32 bit), R G B (24 bit) or 1 R5 G5 B5 big-endian (16 bit). Delta frames only touch changed
/// lines/pixels, so the canvas of the previous frame stays under them.
enum QTRLE {
    static func bytesPerPixel(depth: Int) -> Int? { depth == 32 ? 4 : depth == 24 ? 3 : depth == 16 ? 2 : nil }

    /// Applies one chunk to `canvas` (width * height pixels, straight BGRA in memory, i.e. little-endian 0xAARRGGBB).
    static func apply(_ d: UnsafeBufferPointer<UInt8>, depth: Int, width: Int, height: Int, canvas: UnsafeMutablePointer<UInt32>) throws {
        guard let bpp = bytesPerPixel(depth: depth), d.count >= 6, let src = d.baseAddress else { throw MediaError.truncated }
        let count = d.count
        var p = 4
        let header = Int(src[p]) << 8 | Int(src[p + 1]); p += 2
        var line = 0, lines = height
        if header & 0x0008 != 0 {
            guard count >= p + 8 else { throw MediaError.truncated }
            line = Int(src[p]) << 8 | Int(src[p + 1]); lines = Int(src[p + 4]) << 8 | Int(src[p + 5]); p += 8
        }
        guard line + lines <= height else { throw MediaError.truncated }
        @inline(__always) func pixel(_ at: Int) -> UInt32 {
            switch bpp {
            case 4: return UnsafeRawPointer(src + at).loadUnaligned(as: UInt32.self).byteSwapped   // A R G B -> B G R A bytes
            case 3: return 0xFF00_0000 | UInt32(src[at]) << 16 | UInt32(src[at + 1]) << 8 | UInt32(src[at + 2])
            default:
                let v = UInt32(src[at]) << 8 | UInt32(src[at + 1])
                @inline(__always) func e(_ c: UInt32) -> UInt32 { (c << 3) | (c >> 2) }
                return 0xFF00_0000 | e(v >> 10 & 31) << 16 | e(v >> 5 & 31) << 8 | e(v & 31)
            }
        }
        for row in line..<(line + lines) {
            let dst = canvas + row * width
            guard p < count else { throw MediaError.truncated }
            var x = Int(src[p]) - 1; p += 1
            while true {
                guard p < count else { throw MediaError.truncated }
                let code = Int(Int8(bitPattern: src[p])); p += 1
                if code == -1 { break }
                if code == 0 {
                    guard p < count else { throw MediaError.truncated }
                    x += Int(src[p]) - 1; p += 1; continue
                }
                if code < 0 {
                    let n = -code
                    guard p + bpp <= count else { throw MediaError.truncated }
                    let px = pixel(p); p += bpp
                    let a = max(x, 0), b = min(x + n, width)
                    if a < b { (dst + a).update(repeating: px, count: b - a) }
                    x += n
                } else {
                    let n = code
                    guard p + n * bpp <= count else { throw MediaError.truncated }
                    for k in 0..<n where x + k >= 0 && x + k < width { dst[x + k] = pixel(p + k * bpp) }
                    p += n * bpp; x += n
                }
            }
        }
    }
}

/// Decoder for QuickTime Animation ('rle ') tracks, the transparent-movie export of older After Effects / Final Cut /
/// QuickTime Player; output is the premultiplied BGRA of stills. Delta frames are applied on a persistent canvas.
/// FB-L: such files often have a single key frame, so `AVDemuxer` presents every frame as random access and this
/// decoder restores the chain itself, from whichever is nearest: the canvas (forward play), an LZ4 checkpoint of the
/// canvas (every `interval` frames, thinned to stay in `RLECheckpoints.budget`), or the true key frame (`codedIndex`).
/// Checkpoints (and the background pass that fills them) are shared by all decoders of one media (`RLECheckpoints`).
/// Frames decoded on the way back during a backward jump stay in a small ring, so stepping / dragging backwards is a hit.
public final class RLEDecoder: VideoDecoding, @unchecked Sendable {
    public static let codec: CMVideoCodecType = 0x726C_6520   // 'rle '
    static let ringCapacity = 12

    public let info: VideoTrackInfo
    public var isHardware: Bool { false }
    private let demuxer: any Demuxing
    private let media: UUID
    private let scale: DecodeScale
    private let depth: Int
    private let width: Int, height: Int
    private let pool: BGRAPool
    private let lock = NSLock()
    // Guarded by `lock`.
    private let canvas: UnsafeMutablePointer<UInt32>
    private var canvasIndex: Int?          // frame the canvas currently shows
    private var generation = 0             // bumped on every canvas change (a concurrent call re-plans)
    private var ring: [Int: CVPixelBuffer] = [:]
    private var lastRequest: Int?
    /// Shared per media; thread-safe on its own.
    let checkpoints: RLECheckpoints

    public init(demuxer: any Demuxing, media: UUID, scale: DecodeScale = .full) throws {
        self.demuxer = demuxer; self.media = media; self.scale = scale
        var i = try MediaImporter.videoInfo(format: demuxer.formatDescription, index: demuxer.index, rotation: demuxer.rotation)
        i.chroma = "4:4:4"; i.bitDepth = 8
        info = i
        let dims = CMVideoFormatDescriptionGetDimensions(demuxer.formatDescription)
        width = Int(dims.width); height = Int(dims.height)
        let ext = Self.depth(of: demuxer.formatDescription)
        // Depth 40 / 33 / 34 ... are gray; 1-8 are paletted: not handled.
        guard QTRLE.bytesPerPixel(depth: ext) != nil, width > 0, height > 0 else { throw MediaError.unsupportedCodec("rle \(ext) bit") }
        depth = ext
        pool = BGRAPool(width: width, height: height)
        canvas = .allocate(capacity: width * height)
        canvas.initialize(repeating: 0, count: width * height)
        checkpoints = RLECheckpoints.shared(for: .init(media: media, width: width, height: height, depth: ext))
    }

    deinit { canvas.deallocate() }

    public static func handles(_ format: CMFormatDescription) -> Bool {
        CMFormatDescriptionGetMediaSubType(format) == codec
    }

    /// 'rle ' with a depth this decoder reads (32 / 24 / 16 bit).
    public static func supports(_ format: CMFormatDescription) -> Bool {
        handles(format) && QTRLE.bytesPerPixel(depth: depth(of: format)) != nil
    }

    static func depth(of format: CMFormatDescription) -> Int {
        CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_Depth) as? Int ?? 32
    }

    private struct Plan { var from: Int; var generation: Int; var backward: Bool; var early: DecodedFrame? }

    public func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        let entries = demuxer.index.entries
        guard range.lowerBound >= 0, range.upperBound < entries.count, demuxer.codedIndex.count == entries.count else { throw MediaError.truncated }
        for _ in 0..<4 {
            try Task.checkCancellation()
            let plan = try lock.withLock { try makePlan(range) }
            var out: [DecodedFrame] = plan.early.map { [$0] } ?? []
            if plan.from > range.upperBound { return out }
            // A demuxer may hand out earlier samples than asked (from its own sync sample): the last ones are ours.
            let samples = try await demuxer.samples(for: plan.from...range.upperBound)
            let first = range.upperBound - samples.count + 1
            guard first <= plan.from else { throw MediaError.truncated }
            let done: Bool = try lock.withLock {
                guard generation == plan.generation else { return false }
                for (k, sb) in samples.enumerated() where first + k >= plan.from {
                    try Task.checkCancellation()
                    let idx = first + k
                    try apply(sb, idx)
                    if idx >= range.lowerBound {
                        if entries[idx].duration != .zero { out.append(try frame(idx)) }
                    } else if plan.backward, range.lowerBound - idx <= Self.ringCapacity, entries[idx].duration != .zero {
                        ring[idx] = try makeBuffer()
                    }
                }
                return true
            }
            if done { return out }
        }
        throw MediaError.decodeFailed(-1)
    }

    public func invalidate() { lock.withLock { canvasIndex = nil; generation += 1 } }

    /// Under `lock`: answers a single frame from the ring, or brings the canvas to the cheapest start state for
    /// `range.lowerBound` and says where applying samples starts.
    private func makePlan(_ range: ClosedRange<Int>) throws -> Plan {
        let target = range.lowerBound
        startPrescanIfUseful()
        let backward = lastRequest.map { target < $0 } ?? false
        lastRequest = target
        ring = ring.filter { abs($0.key - target) <= 2 * Self.ringCapacity }
        if range.count == 1, let pb = ring.removeValue(forKey: target) {
            return Plan(from: target + 1, generation: generation, backward: backward, early: try frame(target, pb))
        }
        let coded = demuxer.codedIndex
        let key = coded.entries[target].isSync ? target : coded.previousSync(before: target)
        var best: (cost: Int, kind: Int, at: Int) = (target - key + 1, 0, key)       // 0 = blank canvas from the key
        if let c = canvasIndex, c >= key, c <= target, target - c < best.cost { best = (target - c, 1, c) }
        if let k = checkpoints.latest(in: key...target), target - k + 2 < best.cost { best = (target - k + 2, 2, k) }
        switch best.kind {
        case 1: break
        case 2: try restore(best.at); canvasIndex = best.at; generation += 1
        default:
            // `key` is not a sync frame when none lies at or before the target (stream starts on a delta): blank canvas.
            if !coded.entries[key].isSync { canvas.update(repeating: 0, count: width * height) }
            canvasIndex = nil; generation += 1
        }
        let from = best.kind == 0 ? key : best.at + 1
        var early: DecodedFrame?
        if best.kind != 0, best.at == target, demuxer.index.entries[target].duration != .zero { early = try frame(target) }
        return Plan(from: from, generation: generation, backward: backward, early: early)
    }

    /// Under `lock`.
    private func apply(_ sb: CMSampleBuffer, _ idx: Int) throws {
        generation += 1
        canvasIndex = nil
        try Self.apply(sb, key: demuxer.codedIndex.entries[idx].isSync, depth: depth, width: width, height: height, canvas: canvas)
        canvasIndex = idx
        if checkpoints.wants(idx), let data = Self.compress(canvas, count: width * height * 4) { checkpoints.store(idx, data) }
    }

    static func apply(_ sb: CMSampleBuffer, key: Bool, depth: Int, width: Int, height: Int, canvas: UnsafeMutablePointer<UInt32>) throws {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { throw MediaError.truncated }
        let len = CMBlockBufferGetDataLength(block)
        var data = [UInt8](repeating: 0, count: len)
        let st = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        guard st == kCMBlockBufferNoErr else { throw MediaError.decodeFailed(OSStatus(st)) }
        if key { canvas.update(repeating: 0, count: width * height) }
        try data.withUnsafeBufferPointer { try QTRLE.apply($0, depth: depth, width: width, height: height, canvas: canvas) }
    }

    /// The first decode of a media starts a background walk over the whole clip that leaves a checkpoint every
    /// `interval` frames (own canvas, utility priority), so a first jump far into a single-key clip does not apply every
    /// delta from the start. Only when the demuxer serves exact ranges (random-access index) and the true key frames are
    /// sparse. One walk per media (the shared store runs it and cancels it when the last decoder goes).
    private func startPrescanIfUseful() {
        let demuxer = demuxer, depth = depth, width = width, height = height
        checkpoints.startPrescanOnce { store in
            let coded = demuxer.codedIndex, n = coded.count
            let keys = coded.entries.lazy.filter(\.isSync).count
            let interval = store.interval
            guard n > 2 * interval, n / max(1, keys) > 2 * interval, demuxer.index.entries.allSatisfy(\.isSync) else { return nil }
            return Task.detached(priority: .utility) { [weak store] in
                let canvas = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
                canvas.initialize(repeating: 0, count: width * height)
                defer { canvas.deallocate() }
                var i = 0
                while i < n, !Task.isCancelled {
                    let hi = min(n - 1, i + 29)
                    guard let samples = try? await demuxer.samples(for: i...hi), samples.count == hi - i + 1 else { return }
                    for (k, sb) in samples.enumerated() {
                        let idx = i + k
                        guard (try? Self.apply(sb, key: coded.entries[idx].isSync, depth: depth, width: width, height: height, canvas: canvas)) != nil
                        else { return }
                        guard let store else { return }
                        if store.wants(idx), let data = Self.compress(canvas, count: width * height * 4) { store.store(idx, data) }
                    }
                    i = hi + 1
                }
            }
        }
    }

    private func frame(_ idx: Int, _ pb: CVPixelBuffer? = nil) throws -> DecodedFrame {
        let e = demuxer.index.entries[idx]
        return DecodedFrame(media: media, pts: e.pts, duration: e.duration, pixelBuffer: try pb ?? makeBuffer())
    }

    /// LZ4 copy of a canvas.
    static func compress(_ canvas: UnsafeMutablePointer<UInt32>, count n: Int) -> Data? {
        var dst = Data(count: n + n / 16 + 64)
        let size = dst.withUnsafeMutableBytes { d in
            compression_encode_buffer(d.baseAddress!.assumingMemoryBound(to: UInt8.self), d.count,
                                      UnsafeRawPointer(canvas).assumingMemoryBound(to: UInt8.self), n, nil, COMPRESSION_LZ4)
        }
        guard size > 0 else { return nil }
        dst.count = size
        return dst
    }

    /// Under `lock`.
    private func restore(_ idx: Int) throws {
        guard let data = checkpoints.data(at: idx) else { throw MediaError.truncated }
        let n = width * height * 4
        let got = data.withUnsafeBytes { s in
            compression_decode_buffer(UnsafeMutableRawPointer(canvas).assumingMemoryBound(to: UInt8.self), n,
                                      s.baseAddress!.assumingMemoryBound(to: UInt8.self), s.count, nil, COMPRESSION_LZ4)
        }
        guard got == n else { throw MediaError.decodeFailed(-2) }
    }

    /// Under `lock`. Premultiplied BGRA of the canvas (vImage), at the decode scale.
    private func makeBuffer() throws -> CVPixelBuffer {
        let pb = try pool.make()
        CVPixelBufferLockBaseAddress(pb, [])
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(canvas), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(height), width: vImagePixelCount(width),
                                rowBytes: CVPixelBufferGetBytesPerRow(pb))
        let err = vImagePremultiplyData_RGBA8888(&src, &dst, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(pb, [])
        guard err == kvImageNoError else { throw StillImage.StillError.bufferFailed }
        return try BGRABuffer.scaled(pb, by: scale)
    }
}

/// LZ4 canvas checkpoints of one rle media, shared by all its decoders (Source monitor, Program, export, thumbnails)
/// so the whole-clip background walk runs once and the budget holds per media, not per decoder. Thread-safe; lock
/// order: a decoder's lock may be held while calling in, never the other way round.
final class RLECheckpoints: @unchecked Sendable {
    struct Key: Hashable { let media: UUID; let width: Int, height: Int, depth: Int }
    static let budget = 128 << 20

    private static let registryLock = NSLock()
    private final class Weak { weak var value: RLECheckpoints?; init(_ v: RLECheckpoints) { value = v } }
    nonisolated(unsafe) private static var registry: [Key: Weak] = [:]   // guarded by `registryLock`

    /// The store of `key`, made when no live decoder holds one.
    static func shared(for key: Key) -> RLECheckpoints {
        registryLock.withLock {
            if let s = registry[key]?.value { return s }
            registry = registry.filter { $0.value.value != nil }
            let s = RLECheckpoints()
            registry[key] = Weak(s)
            return s
        }
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var items: [Int: Data] = [:]
    private var bytes = 0
    private var _interval = 8
    private var prescanStarted = false
    private var prescan: Task<Void, Never>?

    deinit { prescan?.cancel() }

    var interval: Int { lock.withLock { _interval } }

    /// `idx` is on the interval and has no checkpoint yet.
    func wants(_ idx: Int) -> Bool { lock.withLock { idx % _interval == 0 && items[idx] == nil } }

    func data(at idx: Int) -> Data? { lock.withLock { items[idx] } }

    /// Latest checkpoint in `range`.
    func latest(in range: ClosedRange<Int>) -> Int? { lock.withLock { items.keys.filter { range.contains($0) }.max() } }

    /// Over budget the interval doubles and off-interval checkpoints go.
    func store(_ idx: Int, _ data: Data) {
        lock.withLock {
            guard idx % _interval == 0, items[idx] == nil else { return }
            items[idx] = data
            bytes += data.count
            while bytes > Self.budget, _interval < 1 << 24 {
                _interval *= 2
                for k in items.keys where k % _interval != 0 { bytes -= items.removeValue(forKey: k)?.count ?? 0 }
            }
        }
    }

    /// Runs `make` once per store (outside the lock); it returns the walk task, or nil when no walk is useful.
    func startPrescanOnce(_ make: (RLECheckpoints) -> Task<Void, Never>?) {
        let first = lock.withLock { () -> Bool in defer { prescanStarted = true }; return !prescanStarted }
        guard first, let task = make(self) else { return }
        lock.withLock { prescan = task }
    }
}

/// Pool of full-size premultiplied BGRA buffers (IOSurface, Metal) for the CPU decoders: no fresh 8 MB allocation and
/// page zeroing per frame. Thread-safe (CVPixelBufferPool).
final class BGRAPool: @unchecked Sendable {
    private let pool: CVPixelBufferPool?
    let width: Int, height: Int

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p
    }

    func make() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        if let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out { return out }
        return try BGRABuffer.make(width: width, height: height)
    }
}

/// BGRA buffer helpers shared by the still-picture decoders.
enum BGRABuffer {
    static func make(width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
              let pb = out else { throw StillImage.StillError.bufferFailed }
        return pb
    }

    /// `pb` (premultiplied BGRA) shrunk by the decode scale divisor (Program monitor quality), `pb` itself at full.
    /// vImage (Lanczos3 on premultiplied data: no dark fringes).
    static func scaled(_ pb: CVPixelBuffer, by scale: DecodeScale) throws -> CVPixelBuffer {
        let d = scale.divisor
        guard d > 1 else { return pb }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let dw = max(1, w / d), dh = max(1, h / d)
        let out = try make(width: dw, height: dh)
        CVPixelBufferLockBaseAddress(pb, .readOnly); CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly); CVPixelBufferUnlockBaseAddress(out, []) }
        var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(h), width: vImagePixelCount(w),
                                rowBytes: CVPixelBufferGetBytesPerRow(pb))
        var dst = vImage_Buffer(data: CVPixelBufferGetBaseAddress(out), height: vImagePixelCount(dh), width: vImagePixelCount(dw),
                                rowBytes: CVPixelBufferGetBytesPerRow(out))
        // Lanczos rings: a color channel can overshoot its alpha, which is no valid premultiplied pixel. Clip to alpha
        // (alpha is the last byte of BGRA, as in RGBA8888).
        guard vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              vImageClipToAlpha_RGBA8888(&dst, &dst, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            throw StillImage.StillError.bufferFailed
        }
        return out
    }
}
