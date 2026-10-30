import CSQFFmpeg
import Foundation
import SQCore
import SQMedia

/// The Windows import probe: `MediaImporter.probe` translated onto FFmpeg. Same result shape as the Mac: a still gets
/// `MediaInfo.defaultStillDuration` and the "image" track of `StillImage.trackInfo`; a movie's video facts come from the
/// demuxer's packet table (`FFmpegDemuxer.trackInfo`, the same index playback uses), its sound from the container; the
/// fingerprint is size, date and the SHA-256 of the first 64 KB, as on the Mac, so relinking matches across platforms.
/// shortcut: no camera metadata, embedded LUT, Dolby Vision or color detection, no animated GIF strips or image
/// sequences; upgrade when Windows playback reads those (the Mac readers are AVFoundation / ImageIO).
public enum FFmpegMediaProbe {
    /// Container facts only (no index).
    public struct Facts: Sendable, Equatable {
        public var duration: Time?
        public var format: String
        public var video: (width: Int, height: Int, frames: Int64, codec: String)?
        public var audio: (rate: Int, channels: Int, codec: String)?
        public static func == (a: Facts, b: Facts) -> Bool {
            a.duration == b.duration && a.format == b.format && a.video?.codec == b.video?.codec && a.audio?.codec == b.audio?.codec
        }

        /// A single picture: an image demuxer ("image2", "png_pipe", "jpeg_pipe", ...) with at most one frame.
        public var isStill: Bool {
            guard video != nil else { return false }
            return (format == "image2" || format.hasSuffix("_pipe")) && (video?.frames ?? -1) <= 1
        }
    }

    public static func facts(_ url: URL) throws -> Facts {
        var p = SQFFProbe()
        var err = [CChar](repeating: 0, count: 256)
        let r = url.withUnsafeFileSystemRepresentation { sq_probe($0, &p, &err, Int32(err.count)) }
        guard r == 0 else { throw FFmpegError.from("probe \(url.lastPathComponent)", r, err) }
        let format = withUnsafeBytes(of: p.format) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let vCodec = withUnsafeBytes(of: p.videoCodec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let aCodec = withUnsafeBytes(of: p.audioCodec) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return Facts(duration: p.durationUs > 0 ? Time(p.durationUs, 1_000_000) : nil, format: format,
                     video: p.hasVideo != 0 ? (Int(p.width), Int(p.height), p.videoFrames, vCodec) : nil,
                     audio: p.hasAudio != 0 ? (Int(p.audioRate), Int(p.audioChannels), aCodec) : nil)
    }

    /// The bin item for `url` (throws `MediaError.unreadable` when FFmpeg finds neither picture nor sound).
    public static func probe(_ url: URL) throws -> MediaRef {
        let f: Facts
        do { f = try facts(url) } catch { throw MediaError.unreadable }
        if f.isStill, let v = f.video {
            let info = MediaInfo(duration: MediaInfo.defaultStillDuration, video: stillTrack(width: v.width, height: v.height),
                                 isStill: true)
            return makeRef(url, duration: info.duration, info: info)
        }
        var video: VideoTrackInfo?
        var duration = f.duration
        if f.video != nil {
            let demux = try FFmpegDemuxer(url: url)
            video = demux.trackInfo
            let d = demux.index.duration
            if d > .zero { duration = d }
        }
        let audio = f.audio.map { AudioTrackInfo(sampleRate: $0.rate > 0 ? $0.rate : 48_000, channels: max(1, $0.channels), codec: $0.codec) }
        guard let duration, video != nil || audio != nil else { throw MediaError.unreadable }
        var info = MediaInfo(duration: duration, video: video, audio: audio)
        info.soundProbed = true
        return makeRef(url, duration: duration, info: info)
    }

    /// `StillImage.trackInfo` (ImageIO file, Mac only).
    static func stillTrack(width: Int, height: Int) -> VideoTrackInfo {
        VideoTrackInfo(width: width, height: height, codec: "image", bitDepth: 8, chroma: "4:4:4",
                       nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
    }

    /// `MediaImporter.makeRef` without the bookmark (Windows paths need none).
    static func makeRef(_ url: URL, duration: Time, info: MediaInfo) -> MediaRef {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var head: String?
        if let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            if let data = try? h.read(upToCount: 64 * 1024) { head = SHA256Digest.hex(data) }
        }
        let fp = MediaFingerprint(size: size, modified: attrs?[.modificationDate] as? Date, headHash: head)
        return MediaRef(name: url.lastPathComponent, path: url.path, fingerprint: fp, duration: duration, info: info)
    }
}
