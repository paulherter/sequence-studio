import Foundation
import SQCore
import SQEditorSession
import SQFrame
import SQMedia
import SQMediaFFmpeg
import SQPlayback
import SQRender

/// One media file for the Windows engines (Program playback and the export frame source): FFmpeg demuxer and decoder,
/// the source-time to frame mapping and the download of decoded frames into NV12 bytes.
struct WinMediaSource: Sendable {
    let demuxer: FFmpegDemuxer
    let decoder: FFmpegVideoDecoder
    /// The track facts (size, rotation, matrix), read once at open.
    let info: VideoTrackInfo

    init(path: String, media: UUID) throws {
        demuxer = try FFmpegDemuxer(url: URL(fileURLWithPath: path))
        decoder = try FFmpegVideoDecoder(demuxer: demuxer, media: media)
        info = demuxer.trackInfo
        WinPlayStats.shared.decoderOpened("\(demuxer.trackInfo.width)x\(demuxer.trackInfo.height) \(decoder.decoderName)")
    }

    var frameCount: Int { demuxer.index.count }

    /// The presentation index a layer at `sourceTime` shows (clamped; past the end: the last frame).
    func frameIndex(at sourceTime: Time) -> Int {
        let idx = demuxer.index
        let first = idx.entries.first?.pts ?? .zero
        let i = idx.frame(at: sourceTime + first) ?? (sourceTime > .zero ? idx.count - 1 : 0)
        return max(0, min(idx.count - 1, i))
    }

    /// Decodes `range` and downloads every frame: 8-bit NV12, or P010 kept at 10 bits (`NV12Picture.bitDepth`).
    /// shortcut: planes through the CPU (hardware frames downloaded); upgrade to D3D11VA shared textures opened on
    /// D3D12 when upload time limits playback (the Windows port plan, Panel status: Engine).
    static func decodePictures(_ decoder: FFmpegVideoDecoder, _ range: ClosedRange<Int>,
                               divisor: Int = 1) async throws -> [(Int, NV12Picture)] {
        var out: [(Int, NV12Picture)] = []
        let stats = WinPlayStats.shared
        let t0 = DispatchTime.now().uptimeNanoseconds
        let frames = try await decoder.decode(range)
        stats.add(.decode, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6, count: max(1, frames.count))
        for (i, f) in zip(range, frames) {
            if let p = try picture(f.frame, divisor: divisor) { out.append((i, p)) }
        }
        return out
    }

    /// Decodes `range` and hands every picture to `deliver` as soon as it is downloaded (on the decoding thread, in
    /// decode order), reduced by `divisor` (1, 2, 4; the playback quality and the layer's drawn size).
    func streamPictures(_ range: ClosedRange<Int>, divisor: Int,
                        deliver: @escaping @Sendable (Int, NV12Picture) -> Void) async throws {
        let index = demuxer.index
        let stats = WinPlayStats.shared
        let lap = Lap()
        let hand: @Sendable (DecodedFrame) -> Void = { f in
            stats.add(.decode, lap.take())
            defer { _ = lap.take() }
            guard let i = index.frame(at: f.frame.presentationTime),
                  let p = try? Self.picture(f.frame, divisor: divisor, threaded: true) else { return }
            deliver(i, p)
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer {
            if Self.trace {
                print(String(format: "decode trace: at %.3f s %@ %d...%d /%d %.1f ms", Double(t0 % 1_000_000_000_000) / 1e9,
                             "\(decoder.media.uuidString.prefix(4)) \(info.width)x\(info.height)", range.lowerBound, range.upperBound, divisor,
                             Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6))
            }
        }
        // Frames the decoder carried from an earlier call come back in the result, not through `hand`.
        for f in try await decoder.decode(range, deliver: hand) {
            if let i = index.frame(at: f.frame.presentationTime), let p = try Self.picture(f.frame, divisor: divisor, threaded: true) {
                deliver(i, p)
            }
        }
    }

    /// `--decode-trace`: every streamed decode prints its range and time (play test diagnostics).
    static let trace = CommandLine.arguments.contains("--decode-trace")

    /// One decoded frame as packed NV12 / P010 bytes, box-reduced by `divisor` (in the download where the format
    /// allows, else after it; a size that does not divide stays full). `threaded` (playback): a full-size picture also
    /// takes the threaded path (a 2-row box from 4:2:2 chroma; download mean 4.8 ms instead of 8.4 for the Oppo 4K 4:2:2
    /// 10-bit clips through swscale),
    /// exports and proxies keep swscale's chroma filter at full size.
    static func picture(_ frame: SQFrame, divisor: Int, threaded: Bool = false) throws -> NV12Picture? {
        guard let ff = frame.storage as? FFmpegFrame else { return nil }
        let full = frame.pixelFormat == .nv12FullRange || frame.pixelFormat == .p010FullRange
        let stats = WinPlayStats.shared
        if divisor > 1 || threaded, let r = try stats.time(.download, { try ff.download(divisor: divisor) }) {
            var p = NV12Picture(bytes: r.bytes, width: r.width, height: r.height, fullRange: full)
            if r.bytes.count >= r.width * r.height * 3 { p.bitDepth = 10 }
            return p
        }
        let bytes = try stats.time(.download) { try ff.download() }
        let w = frame.width, h = frame.height
        var p = NV12Picture(bytes: bytes, width: w, height: h, fullRange: full)
        if bytes.count >= w * h * 3 { p.bitDepth = 10 }   // two bytes per sample: P010
        guard divisor > 1 else { return p }
        // No reduced download for this format: reduce the full picture.
        // shortcut: a 10-bit picture reduced here drops to 8 bits (preview only, formats the C path lacks); widen
        // sq_frame_download_reduced when such media plays reduced often.
        let e = p.eightBit
        guard let r = stats.time(.reduce, { NV12Reduce.reduce(e.bytes, width: e.width, height: e.height, by: divisor) }) else { return p }
        return NV12Picture(bytes: r.bytes, width: r.width, height: r.height, fullRange: full)
    }

    /// The per-layer color pipelines (conversion, Lumetri, LUT files) as on the Mac (`ProjectMediaResolver.colorResolver`).
    /// shortcut: no embedded LUTs (read from camera clip metadata on the Mac); add them with a portable metadata reader.
    static func colorResolver(_ table: MediaInfoTable) -> LayerColorResolver {
        let provider = CachingLUTProvider(file: { MediaManagement.resolveStoredPath($0, projectFolder: nil).flatMap { FileManager.default.contents(atPath: $0) } },
                                          embedded: { _ in nil },
                                          stamp: { MediaManagement.resolveStoredPath($0, projectFolder: nil).flatMap { LUTStamp.ofFile($0) } })
        return LayerColorResolver(lutProvider: provider) { table.info($0) }
    }
}

/// Milliseconds since the last `take` (the decode share of a streamed decode, between two delivered frames).
private final class Lap: @unchecked Sendable {
    private var t = DispatchTime.now().uptimeNanoseconds
    func take() -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        defer { t = now }
        return Double(now - t) / 1e6
    }
}
