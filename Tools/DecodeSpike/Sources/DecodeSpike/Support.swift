import AVFoundation
import VideoToolbox
import CoreMedia

@inline(__always) func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

struct Stats {
    var v: [Double]
    var median: Double { pct(0.5) }
    var p95: Double { pct(0.95) }
    var max: Double { v.max() ?? 0 }
    func pct(_ p: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted(); return s[Swift.min(s.count - 1, Int(Double(s.count) * p))]
    }
    var text: String { String(format: "med %.1f / p95 %.1f / max %.1f ms (n=%d)", median, p95, max, v.count) }
}

final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func inc() { l.lock(); n += 1; l.unlock() }
    func reset() { l.lock(); n = 0; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return n }
}

func fourCC(_ c: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((c >> $0) & 0xff) }, encoding: .macOSRoman) ?? "\(c)"
}

struct ClipInfo {
    var name = "", codec = "", profile = "", pixel = "", color = ""
    var width = 0, height = 0, bits = 0
    var fps = 0.0, duration = 0.0, mbps = 0.0
    var frames = 0, syncFrames = 0, chroma = 0
    var pts: [CMTime] = []       // presentation order
    var frameDuration = CMTime.invalid
    var format: CMFormatDescription!
}

func probe(_ url: URL) async throws -> ClipInfo {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    var info = ClipInfo(); info.name = url.lastPathComponent
    let fds = try await track.load(.formatDescriptions)
    let fd = fds[0]; info.format = fd
    info.codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
    let dims = CMVideoFormatDescriptionGetDimensions(fd)
    info.width = Int(dims.width); info.height = Int(dims.height)
    info.fps = Double(try await track.load(.nominalFrameRate))
    info.duration = try await asset.load(.duration).seconds
    info.frameDuration = try await track.load(.minFrameDuration)
    info.mbps = Double(try await track.load(.estimatedDataRate)) / 1e6
    let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
    if let b = ext["BitsPerComponent"] as? Int { info.bits = b }
    let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Data] ?? [:]
    if let a = atoms["avcC"], a.count > 4 {
        let p = a[a.startIndex + 1]
        let names: [UInt8: String] = [66: "Baseline", 77: "Main", 88: "Extended", 100: "High", 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4"]
        info.profile = "avc \(names[p] ?? "\(p)") L\(Double(a[a.startIndex + 3]) / 10)"
        if p >= 100, a.count >= 4 {
            // avcC trailer for high profiles: [.. chroma_format, bit_depth_luma-8, bit_depth_chroma-8, numSPSExt ..]
            let tail = Array(a.suffix(4))
            if tail[0] & 3 != 0 || tail[1] & 7 != 0 || true { info.bits = Int(tail[1] & 7) + 8; info.chroma = Int(tail[0] & 3); info.profile += " chroma_idc \(tail[0] & 3)" }
        }
    } else if let a = atoms["hvcC"], a.count > 17 {
        let s = a.startIndex
        info.profile = "hevc profile \(a[s + 1] & 0x1f) chroma \(a[s + 16] & 3) luma \(Int(a[s + 17] & 7) + 8)-bit"
        if info.bits == 0 { info.bits = Int(a[s + 17] & 7) + 8 }
        info.chroma = Int(a[s + 16] & 3)
    }
    let prim = ext["CVImageBufferColorPrimaries"] as? String ?? "?"
    let tf = ext["CVImageBufferTransferFunction"] as? String ?? "?"
    let mx = ext["CVImageBufferYCbCrMatrix"] as? String ?? "?"
    info.color = "\(prim) / \(tf) / \(mx)"

    // Passthrough scan: frame count, keyframe count, PTS list.
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    out.alwaysCopiesSampleData = false
    reader.add(out); reader.startReading()
    while let sb = out.copyNextSampleBuffer() {
        info.frames += 1
        info.pts.append(CMSampleBufferGetPresentationTimeStamp(sb))
        let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first
        if att?[kCMSampleAttachmentKey_NotSync] as? Bool != true { info.syncFrames += 1 }
    }
    info.pts.sort { $0 < $1 }
    return info
}

// MARK: - VideoToolbox session

enum HWMode: String { case auto, requireHW, forceSW }

final class VTDec {
    let session: VTDecompressionSession
    var usingHW: Bool?
    var pixelFormat: OSType = 0
    let frames = Counter()
    let errors = Counter()
    nonisolated(unsafe) var lastError: OSStatus = 0
    private let lock = NSLock()
    private var arrived: [Double: Double] = [:]   // pts seconds -> wallclock

    init?(format: CMFormatDescription, mode: HWMode) {
        var spec: [CFString: Any] = [:]
        switch mode {
        case .auto: spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true
        case .requireHW: spec[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = true
        case .forceSW: spec[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = false
        }
        let dest: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                              imageBufferAttributes: dest as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else { return nil }
        session = s
        var v: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &v)
        usingHW = (v as? Bool)
    }
    deinit { VTDecompressionSessionInvalidate(session) }

    /// Decodes one compressed sample. Returns false on error.
    @discardableResult
    func decode(_ sb: CMSampleBuffer, async: Bool, noOutput: Bool = false) -> OSStatus {
        var flags: VTDecodeFrameFlags = []
        if async { flags.insert(._EnableAsynchronousDecompression) }
        if noOutput { flags.insert(._DoNotOutputFrame) }
        var info = VTDecodeInfoFlags()
        return VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: flags, infoFlagsOut: &info) { [self] status, _, image, pts, _ in
            guard status == noErr, let image else { if status != noErr { errors.inc(); lastError = status }; return }
            pixelFormat = CVPixelBufferGetPixelFormatType(image)
            frames.inc()
            lock.lock(); arrived[pts.seconds] = nowMs(); lock.unlock()
        }
    }
    func drain() { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    func arrival(of pts: CMTime) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return arrived.first { abs($0.key - pts.seconds) < 0.0005 }?.value
    }
    func reset() { lock.lock(); arrived = [:]; lock.unlock() }
}

/// Pixel format the custom compositor asks AVFoundation to deliver (native bit depth / chroma of the clip).
func nativeFormat(_ i: ClipInfo) -> OSType {
    switch (i.bits, i.chroma) {
    case (10..., 2): return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    case (10..., _): return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    default: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
}
