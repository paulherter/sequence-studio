import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import SQCore

public enum MediaImporter {
    public static func probe(_ url: URL) async throws -> (MediaRef, MediaInfo) {
        if StillImage.isStill(url) {
            // Animated GIF / APNG / WebP play as a clip (cached strip); a failure falls back to the first frame as a still.
            if AnimatedImage.info(of: url) != nil, let animated = try? await probeAnimated(url) { return animated }
            return try probeStill(url)
        }
        if WebMFile.isWebM(url) { return try await probeWebM(url) }
        if MXFFile.isMXF(url) { return try probeMXF(url) }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), let dur = Time(duration) else { throw MediaError.unreadable }
        let vTrack = try? await asset.loadTracks(withMediaType: .video).first
        let aTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let usableA = await MultiTrackAudio.usableTracks(aTracks)      // the same list playback and the proxy use
        let aTrack = usableA.first?.track ?? aTracks.first
        guard vTrack != nil || aTrack != nil else { throw MediaError.unreadable }

        var video: VideoTrackInfo?
        var dolbyVision: DolbyVisionConfig?
        if let vTrack {
            let handoffKey = DemuxerHandoff.key(url)   // taken before the sample-table walk
            let demux = try await AVDemuxer(url: url)
            try VideoDecodability.requireDecodable(demux.formatDescription)
            video = try videoInfo(format: demux.formatDescription, index: demux.index, rotation: demux.rotation)
            dolbyVision = ColorDetection.dolbyVision(of: demux.formatDescription)
            DemuxerHandoff.store(demux, for: url, key: handoffKey)      // the project's first open of this file reuses it
        }
        var audio: AudioTrackInfo?
        if let aTrack, let fd = try? await aTrack.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            // F7.10: channels count across all audio tracks (track order, then channel order), so each can be chosen.
            let counts = usableA.map(\.channels)
            let multi = counts.count > 1
            audio = AudioTrackInfo(sampleRate: Int(asbd.mSampleRate.rounded()) > 0 ? Int(asbd.mSampleRate.rounded()) : 48_000, channels: multi ? counts.reduce(0, +) : Int(asbd.mChannelsPerFrame),
                                   codec: fourCC(CMFormatDescriptionGetMediaSubType(fd)),
                                   firstTrackChannels: multi ? counts[0] : nil)
        }
        if audio == nil, let aTrack {      // a sound track that exists but cannot be described: plays without sound
            let fd = try? await aTrack.load(.formatDescriptions).first
            ImportNotes.noteAudioDropped(url, codec: fd.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown")
        }
        var info = MediaInfo(duration: dur, video: video, audio: audio)
        info.soundProbed = true
        var sonyModel: String?
        if let v = video {
            // Detected once here; Sony metadata and the embedded camera LUT are best-effort (nil on any error).
            let camera = CameraMetadata.read(forClip: url)     // Sony and Canon in one walk over the boxes
            sonyModel = camera.sony?.modelName
            info.detectedColorSpace = ColorDetection.detect(colorPrimaries: v.colorPrimaries, transfer: v.transfer,
                                                            sony: camera.sony, dolbyVision: dolbyVision, canon: camera.canon)
            if let lut = (try? EmbeddedMeta.lutHeader(inClip: url)) ?? nil {     // name only: no cube text at import
                info.embeddedLUTName = lut.name ?? "Embedded LUT"
            }
        }
        let shoot = await ShootMetadata.read(url, sonyModel: sonyModel, walkedBoxes: video != nil)
        info.created = shoot.created; info.cameraModel = shoot.cameraModel; info.shootProbed = true

        return makeRef(url, duration: dur, info: info)
    }

    /// Default number of files probed at once: probing waits mostly on file reads and AVFoundation loads, so a few in
    /// flight hide the latency; bounded so a weak Mac (8 GB, 8 cores) is not flooded with sample-table walks.
    public static var defaultProbeConcurrency: Int { min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)) }

    /// Probes `urls` with at most `concurrency` in flight; one result per url, in input order, failures in place.
    public static func probeAll<T: Sendable>(_ urls: [URL], concurrency: Int = defaultProbeConcurrency,
                                             probe: @escaping @Sendable (URL) async throws -> T) async -> [Result<T, Error>] {
        var out = [Result<T, Error>?](repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, Result<T, Error>).self) { group in
            var next = 0
            func add() {
                let i = next, url = urls[i]
                next += 1
                group.addTask { do { return (i, .success(try await probe(url))) } catch { return (i, .failure(error)) } }
            }
            while next < min(max(1, concurrency), urls.count) { add() }
            while let (i, r) = await group.next() {
                out[i] = r
                if next < urls.count { add() }
            }
        }
        return out.map { $0! }
    }

    /// `probeAll` with `probe(_:)`.
    public static func probeAll(_ urls: [URL], concurrency: Int = defaultProbeConcurrency) async -> [Result<(MediaRef, MediaInfo), Error>] {
        await probeAll(urls, concurrency: concurrency) { try await probe($0) }
    }

    /// WebM / Matroska: AVFoundation cannot open these; `WebMFile` reads the structure, `WebMDemuxer` describes the video.
    /// Video with a codec this Mac cannot decode throws `MediaError.unsupportedCodec` (the import dialog names it);
    /// audio with an unsupported codec imports as video without audio.
    static func probeWebM(_ url: URL) async throws -> (MediaRef, MediaInfo) {
        let file = try WebMFile.open(url)
        var video: VideoTrackInfo?
        var videoEnd: Time = .zero
        if file.track(.video) != nil {
            let handoffKey = DemuxerHandoff.key(url)
            let demux = try WebMDemuxer(file: file)
            try VideoDecodability.requireDecodable(demux.formatDescription)
            video = try videoInfo(format: demux.formatDescription, index: demux.index, rotation: 0)
            DemuxerHandoff.store(demux, for: url, key: handoffKey)
            videoEnd = demux.index.duration
        }
        var audio: AudioTrackInfo?
        var audioEnd: Time = .zero
        if file.track(.audio) != nil {
            do {
                let src = try WebMAudioSource(file: file, sampleRate: 48_000)
                let t = file.track(.audio)!
                // AAC: the decoder's rate and channels come from the AudioSpecificConfig, so report those.
                let asc = t.codecID == "A_AAC" ? AACPacketDecoder.parse(config: t.codecPrivate) : nil
                audio = AudioTrackInfo(sampleRate: (asc?.rate).flatMap { $0 > 0 ? $0 : nil } ?? (Int(t.sampleRate.rounded()) > 0 ? Int(t.sampleRate.rounded()) : 48_000),
                                       channels: asc?.channels ?? max(1, t.channels), codec: Self.matroskaAudioName(t.codecID))
                audioEnd = Time(src.totalFrames, 48_000)
            } catch MediaError.unsupportedCodec(let codec) {
                audio = nil
                ImportNotes.noteAudioDropped(url, codec: codec)
            }
        }
        guard video != nil || audio != nil else { throw MediaError.unreadable }
        let dur = max(videoEnd, audioEnd)
        var info = MediaInfo(duration: dur, video: video, audio: audio)
        if let v = video {
            info.detectedColorSpace = ColorDetection.detect(colorPrimaries: v.colorPrimaries, transfer: v.transfer, sony: nil)
        }
        return makeRef(url, duration: dur, info: info)
    }

    /// MXF (Sony XAVC and other frame-wrapped OP1a): own demuxer, AVFoundation only reads MXF with extra software.
    /// Audio the demuxer cannot read imports as video without audio; unsupported video is an error naming the codec.
    static func probeMXF(_ url: URL) throws -> (MediaRef, MediaInfo) {
        let file = try MXFFile.open(url)
        var video: VideoTrackInfo?
        var videoEnd: Time = .zero
        if file.videoTrack != nil {
            let handoffKey = DemuxerHandoff.key(url)
            let demux = try MXFDemuxer(file: file)
            var v = try videoInfo(format: demux.formatDescription, index: demux.index, rotation: 0)
            // The descriptor knows depth and chroma where the format description does not (ProRes flavors do).
            if let p = file.videoTrack?.picture, CMFormatDescriptionGetMediaSubType(demux.formatDescription) != kCMVideoCodecType_H264 {
                if p.componentDepth >= 8 { v.bitDepth = p.componentDepth }
            }
            // Field order comes from the descriptor (already parsed with the header partition); PsF stays progressive.
            v.fieldOrder = file.videoTrack?.picture?.fieldOrder
            video = v
            DemuxerHandoff.store(demux, for: url, key: handoffKey)
            videoEnd = demux.index.duration
        }
        var audio: AudioTrackInfo?
        var audioEnd: Time = .zero
        if !file.soundTracks.isEmpty {
            do {
                let src = try MXFAudioSource(file: file, sampleRate: 48_000)
                audio = AudioTrackInfo(sampleRate: src.nativeRate, channels: src.channelCount, codec: "PCM")
                audioEnd = Time(src.totalFrames, 48_000)
            } catch MediaError.unsupportedCodec(let codec) {
                ImportNotes.noteAudioDropped(url, codec: codec)
            } catch {}
        }
        guard video != nil || audio != nil else { throw MediaError.unreadable }
        let dur = video != nil ? videoEnd : audioEnd
        var info = MediaInfo(duration: dur, video: video, audio: audio)
        if let v = video {
            let camera = CameraMetadata.read(forClip: url, boxes: false)
            info.detectedColorSpace = ColorDetection.detect(colorPrimaries: v.colorPrimaries, transfer: v.transfer,
                                                            sony: camera.sony, canon: camera.canon)
        }
        return makeRef(url, duration: dur, info: info)
    }

    static func matroskaAudioName(_ id: String) -> String {
        switch id {
        case "A_OPUS": return "Opus"
        case "A_AAC": return "AAC"
        case "A_PCM/INT/LIT", "A_PCM/FLOAT/IEEE": return "PCM"
        default: return "Vorbis"
        }
    }

    /// Still image: size from ImageIO, default length `MediaInfo.defaultStillDuration`, no audio.
    static func probeStill(_ url: URL) throws -> (MediaRef, MediaInfo) {
        guard let size = try? StillImage.size(of: url) else { throw MediaError.unreadable }
        let info = MediaInfo(duration: MediaInfo.defaultStillDuration,
                             video: StillImage.trackInfo(width: size.width, height: size.height), isStill: true)
        return makeRef(url, duration: info.duration, info: info)
    }

    private static func makeRef(_ url: URL, duration dur: Time, info: MediaInfo) -> (MediaRef, MediaInfo) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let fp = MediaFingerprint(size: size, modified: attrs?[.modificationDate] as? Date, headHash: headHash(url))
        let bookmark = MediaBookmark.make(for: url)
        let ref = MediaRef(name: url.lastPathComponent, path: url.path, bookmark: bookmark, fingerprint: fp,
                           duration: dur, info: info)
        return (ref, info)
    }

    static func videoInfo(format fd: CMFormatDescription, index: SampleIndex, rotation: Int = 0) throws -> VideoTrackInfo {
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let sub = CMFormatDescriptionGetMediaSubType(fd)
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let (chroma, depth) = chromaAndDepth(subType: sub, extensions: ext)

        // Frame duration: most common pts delta; VFR when deltas are not (almost) constant.
        // Shown frames only: samples an edit list cuts out have zero duration (SampleIndex).
        var counts: [Time: Int] = [:]
        let e = index.entries.filter { $0.duration > .zero }
        for i in 1..<max(1, e.count) { counts[e[i].pts - e[i - 1].pts, default: 0] += 1 }
        let modal = counts.max { $0.value < $1.value }?.key ?? e.first?.duration ?? index.entries.first?.duration ?? Time(1, 30)
        // Sequence-facing rate: average over the whole clip snapped to a standard rate (a per-sample delta misleads on VFR).
        let nominal = e.count > 1 ? FrameRate.sequenceFrameDuration(frameCount: e.count, duration: index.duration) : modal
        // VFR when a delta is more than 2 % off the modal one, except timescale rounding: 59.94 in timescale 600 is
        // 10/600 with an 11/600 now and then (iPhone), i.e. one tick of the track timescale.
        let tick = timescaleTick(of: Array(counts.keys), below: modal)
        let vfr = counts.count > 1 && counts.keys.contains { d in
            let dev = d < modal ? modal - d : d - modal
            if let tick, dev <= tick { return false }
            return Int128(dev.value) * Int128(modal.timescale) * 50 > Int128(modal.value) * Int128(dev.timescale)
        }

        func tag(_ key: CFString) -> String? { ext[key as String] as? String }
        return VideoTrackInfo(width: Int(dims.width), height: Int(dims.height), codec: fourCC(sub), bitDepth: depth, chroma: chroma,
                              nominalFrameDuration: nominal, isVariableFrameRate: vfr,
                              colorPrimaries: tag(kCMFormatDescriptionExtension_ColorPrimaries),
                              transfer: ColorDetection.transferTag(extensions: ext),
                              matrix: tag(kCMFormatDescriptionExtension_YCbCrMatrix), rotation: rotation,
                              pixelAspect: PixelAspectTag.pixelAspect(extensions: ext), fieldOrder: fieldOrder(extensions: ext))
    }

    /// Field order a format description tags (MOV `fiel` atom, lifted by the system parser): two fields and which one
    /// is earlier. nil = progressive or untagged.
    static func fieldOrder(extensions ext: [String: Any]) -> FieldOrder? {
        guard (ext[kCMFormatDescriptionExtension_FieldCount as String] as? NSNumber)?.intValue == 2 else { return nil }
        let detail = ext[kCMFormatDescriptionExtension_FieldDetail as String] as? String
        let bottomFirst = detail == (kCMFormatDescriptionFieldDetail_TemporalBottomFirst as String)
            || detail == (kCMFormatDescriptionFieldDetail_SpatialFirstLineLate as String)
        return bottomFirst ? .bottomFirst : .topFirst
    }

    /// Greatest common step of the frame deltas (the track timescale tick they are counted in), when it is clearly finer
    /// than a frame (at most a quarter of `modal`); nil otherwise (deltas that are whole multiples of a frame are real VFR).
    static func timescaleTick(of deltas: [Time], below modal: Time) -> Time? {
        guard deltas.count > 1 else { return nil }
        func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? Swift.abs(a) : gcd(b, a % b) }
        var lcm: Int64 = 1
        for d in deltas {
            let (m, o) = (lcm / gcd(lcm, d.timescale)).multipliedReportingOverflow(by: d.timescale)
            if o { return nil }
            lcm = m
        }
        var g: Int64 = 0
        for d in deltas {
            let (v, o) = d.value.multipliedReportingOverflow(by: lcm / d.timescale)
            if o { return nil }
            g = gcd(g, v)
        }
        guard g > 0 else { return nil }
        let tick = Time(g, lcm)
        return tick * 4 <= modal ? tick : nil
    }

    static func chromaAndDepth(subType: FourCharCode, extensions ext: [String: Any]) -> (String, Int) {
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Data] ?? [:]
        switch fourCC(subType) {
        case "avc1", "avc3":
            if let d = atoms["avcC"], let r = CodecConfig.avc(d) { return (r.chroma, r.bitDepth) }
            return ("4:2:0", 8)
        case "hvc1", "hev1", "dvh1", "dvhe":   // dvh1 / dvhe: Dolby Vision sample entries, HEVC underneath
            if let d = atoms["hvcC"], let r = CodecConfig.hevc(d) { return (r.chroma, r.bitDepth) }
            return ("4:2:0", 10)
        case "vp09":
            if let d = atoms["vpcC"], let r = CodecConfig.vp9(d) { return (r.chroma, r.bitDepth) }
            return ("4:2:0", 8)
        case "av01":
            if let d = atoms["av1C"], let r = CodecConfig.av1(d) { return (r.chroma, r.bitDepth) }
            return ("4:2:0", 8)
        case "apch", "apcn", "apcs", "apco": return ("4:2:2", 10)
        case "ap4h", "ap4x": return ("4:4:4", (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int) ?? 12)
        default: return ("4:2:0", (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int) ?? 8)
        }
    }

    private static func headHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64 * 1024) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

func fourCC(_ c: FourCharCode) -> String {
    String(decoding: [UInt8((c >> 24) & 255), UInt8((c >> 16) & 255), UInt8((c >> 8) & 255), UInt8(c & 255)], as: UTF8.self)
}
