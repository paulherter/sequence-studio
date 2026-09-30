import AVFoundation
import VideoToolbox
import CoreMedia
import Foundation

let maxFrames = 240

func report(_ s: String) { print(s); fflush(stdout) }

// MARK: Route A — AVFoundation (reader, composition + custom compositor, player seeks)

func routeAReaderFPS(url: URL, info: ClipInfo, withCompositor: Bool) async throws -> (fps: Double, fmt: String) {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader: AVAssetReader
    let out: AVAssetReaderOutput
    var fmt = ""
    if withCompositor {
        let (comp, vc) = try await makeComposition(url: url, info: info)
        reader = try AVAssetReader(asset: comp)
        let o = AVAssetReaderVideoCompositionOutput(videoTracks: try await comp.loadTracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
        o.videoComposition = vc; out = o
    } else {
        reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
        out = o
    }
    reader.add(out); reader.startReading()
    var n = 0; var t0 = 0.0
    while let sb = out.copyNextSampleBuffer(), n < maxFrames + 1 {
        if n == 0 { t0 = nowMs(); if let px = CMSampleBufferGetImageBuffer(sb) { fmt = fourCC(CVPixelBufferGetPixelFormatType(px)) } }
        n += 1
    }
    reader.cancelReading()
    let dt = nowMs() - t0
    return (Double(n - 1) / (dt / 1000), fmt)
}

func seek(_ p: AVPlayer, _ t: CMTime) async {
    await withCheckedContinuation { c in p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { _ in c.resume() } }
}

func routeAPlayer(url: URL, info: ClipInfo) async throws -> (random: Stats, step: Stats, fmt: String) {
    let (comp, vc) = try await makeComposition(url: url, info: info)
    let item = AVPlayerItem(asset: comp)
    item.videoComposition = vc
    let vo = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
    item.add(vo)
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = false
    await seek(player, .zero)
    try await Task.sleep(for: .milliseconds(500))
    let tol = info.frameDuration.seconds / 2

    func timed(_ t: CMTime) async -> Double? {
        SpikeCompositor.reset()
        let t0 = nowMs()
        await seek(player, t)
        for _ in 0..<3000 {
            if let w = SpikeCompositor.arrival(of: t.seconds, tol: tol) { return w - t0 }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }
    var rng = SystemRandomNumberGenerator()
    var random: [Double] = []
    for _ in 0..<20 {
        let t = info.pts[Int.random(in: 0..<info.frames, using: &rng)]
        if let d = await timed(t) { random.append(d) }
    }
    // Adjacent-frame stepping (drag-scrub at 1 frame per step) from mid-clip.
    var step: [Double] = []
    let start = info.frames / 2
    for i in 0..<30 where start + i < info.frames {
        if let d = await timed(info.pts[start + i]) { step.append(d) }
    }
    return (Stats(v: random), Stats(v: step), fourCC(SpikeCompositor.srcFormat))
}

// MARK: Route B — direct VideoToolbox

func routeBSequential(url: URL, info: ClipInfo, mode: HWMode) async throws -> (fps: Double, hw: Bool?, fmt: String)? {
    guard let dec = VTDec(format: info.format, mode: mode) else { return nil }
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let gen = AVSampleBufferGenerator(asset: asset, timebase: nil)
    guard let c = track.makeSampleCursor(presentationTimeStamp: .zero) else { return nil }
    var n = 0; var t0 = 0.0
    while n < maxFrames + 1 {
        let req = AVSampleBufferRequest(start: c)
        req.direction = .forward; req.maxSampleCount = 1
        guard let sb = try? gen.createSampleBuffer(for: req) else { break }
        if n == 1 { dec.drain(); t0 = nowMs(); dec.frames.reset() }
        let st = dec.decode(sb, async: true)
        if st != noErr { report("   decode error \(st) at frame \(n)"); break }
        if c.stepInDecodeOrder(byCount: 1) != 1 { break }
        n += 1
    }
    dec.drain()
    let dt = nowMs() - t0
    let out = dec.frames.value
    return (Double(out) / (dt / 1000), dec.usingHW, fourCC(dec.pixelFormat) + " | \(out)/\(n) frames out, \(dec.errors.value) errors (last \(dec.lastError))")
}

/// Random access: back to the previous sync sample, decode forward to the target. Cold session state each time is not
/// forced — the session persists (as a real scrubber would), but no frame cache is used.
func routeBRandom(url: URL, info: ClipInfo, mode: HWMode) async throws -> Stats? {
    guard let dec = VTDec(format: info.format, mode: mode) else { return nil }
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let gen = AVSampleBufferGenerator(asset: asset, timebase: nil)
    var times: [Double] = []
    var rng = SystemRandomNumberGenerator()
    var used = 0
    for _ in 0..<20 {
        let target = info.pts[Int.random(in: 0..<info.frames, using: &rng)]
        guard let tc = track.makeSampleCursor(presentationTimeStamp: target) else { continue }
        let t0 = nowMs()
        let c = tc.copy() as! AVSampleCursor
        var back = 0
        while !c.currentSampleSyncInfo.sampleIsFullSync.boolValue, c.stepInDecodeOrder(byCount: -1) == -1 { back += 1 }
        let count = back + 1
        for i in 0..<count {
            let req = AVSampleBufferRequest(start: c)
            req.direction = .forward; req.maxSampleCount = 1
            guard let sb = try? gen.createSampleBuffer(for: req) else { break }
            let st = dec.decode(sb, async: i < count - 1, noOutput: i < count - 1)
            if st != noErr { report("   decode error \(st) at \(i)/\(count)"); break }
            _ = c.stepInDecodeOrder(byCount: 1)
        }
        dec.drain()
        times.append(nowMs() - t0); used = max(used, count)
    }
    report("      (max decode-from-sync depth: \(used) frames)")
    return Stats(v: times)
}

// MARK: Run

let clips = [
    ("Sony", "\(NSHomeDirectory())/Documents/Videos/iOS 27 Features #2/C2160.MP4"),
    ("iPhone", "\(NSHomeDirectory())/Documents/Videos/Käsiger michael/IMG_1281.MOV"),
]
let only = CommandLine.arguments.dropFirst().first
if only == "scan" {
    let root = URL(fileURLWithPath: "\(NSHomeDirectory())/Documents/Videos")
    for case let u as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! where ["mov", "mp4"].contains(u.pathExtension.lowercased()) {
        guard let t = try? await AVURLAsset(url: u).loadTracks(withMediaType: .video).first, let fd = try? await t.load(.formatDescriptions).first else { continue }
        let e = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let d = CMVideoFormatDescriptionGetDimensions(fd)
        report("\(fourCC(CMFormatDescriptionGetMediaSubType(fd))) \(d.width)x\(d.height) \(e["CVImageBufferTransferFunction"] ?? "?") \(e["BitsPerComponent"] ?? "-")  \(u.path.replacingOccurrences(of: root.path, with: ""))")
    }
    exit(0)
}

let extra: [(String, String)] = only.flatMap { FileManager.default.fileExists(atPath: $0) ? [("Extra", $0)] : nil } ?? []
for (label, path) in (extra.isEmpty ? clips : extra) where only == nil || only == label || !extra.isEmpty {
    let url = URL(fileURLWithPath: path)
    let info = try await probe(url)
    SpikeCompositor.wantFormat = nativeFormat(info)
    report("\n=== \(label): \(info.name)")
    report("  \(info.codec) \(info.profile) \(info.width)x\(info.height) \(String(format: "%.3f", info.fps)) fps, \(info.bits)-bit, \(String(format: "%.0f", info.mbps)) Mbit/s, \(String(format: "%.1f", info.duration)) s")
    report("  frames \(info.frames), sync frames \(info.syncFrames) (GOP≈\(info.syncFrames > 0 ? info.frames / info.syncFrames : 0)), color \(info.color)")
    report("  VTIsHardwareDecodeSupported: \(VTIsHardwareDecodeSupported(CMFormatDescriptionGetMediaSubType(info.format)))")

    for mode in [HWMode.requireHW, .forceSW] {
        if let r = try await routeBSequential(url: url, info: info, mode: mode) {
            report("  [B] VT \(mode.rawValue): \(String(format: "%.1f", r.fps)) fps sequential (decoded output), usingHW=\(r.hw.map(String.init) ?? "?"), out \(r.fmt)")
        } else { report("  [B] VT \(mode.rawValue): session creation FAILED") }
    }
    for mode in [HWMode.auto] {
        if let s = try await routeBRandom(url: url, info: info, mode: mode) { report("  [B] VT random access (\(mode.rawValue)): \(s.text)") }
    }
    let r1 = try await routeAReaderFPS(url: url, info: info, withCompositor: false)
    report("  [A] AVAssetReader decode: \(String(format: "%.1f", r1.fps)) fps, out \(r1.fmt)")
    let r2 = try await routeAReaderFPS(url: url, info: info, withCompositor: true)
    report("  [A] AVAssetReader + AVComposition + custom compositor: \(String(format: "%.1f", r2.fps)) fps")
    let p = try await routeAPlayer(url: url, info: info)
    report("  [A] AVPlayer+compositor random seek: \(p.random.text)")
    report("  [A] AVPlayer+compositor 1-frame step seek: \(p.step.text) (source fmt \(p.fmt))")
}
exit(0)
