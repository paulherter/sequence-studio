import CoreMedia
import Foundation
import Synchronization
import VideoToolbox

/// Plain-language reason a file could not be imported. Looks at the file itself (existence, size, the first bytes, the
/// top-level atoms of MP4/MOV) so the message names what is wrong instead of "could not read". Cheap: a few bytes of I/O,
/// meant for files that already failed to probe.
public enum MediaDiagnosis {
    /// A container Sequence Studio does not open, found by its first bytes: (display name, what to convert it to).
    struct Container: Equatable { let name: String; let advice: String }

    public static func reason(for url: URL, error: Error? = nil) -> String {
        if case MediaError.unsupportedCodec(let codec)? = error as? MediaError {
            if let c = codecAdvice(codec) { return "\(c.name) files are not supported. \(c.advice)" }
            return "Uses \(codec), which this Mac cannot decode."
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return "The file is no longer there." }
        if isDir.boolValue { return "This is a folder, not a media file." }
        guard fm.isReadableFile(atPath: url.path) else {
            return "Sequence Studio is not allowed to read this file. Check its permissions or the folder's access."
        }
        let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if size == 0 { return "The file is empty (0 bytes). The copy or download probably did not finish." }
        let ext = url.pathExtension.lowercased()
        if ext == "m4p" { return "The file is copy protected (DRM) and cannot be read." }
        let head = readHead(url, count: 16)
        if let c = container(head: head, ext: ext, stem: url.deletingPathExtension().lastPathComponent) {
            return "\(c.name) files are not supported. \(c.advice)"
        }
        if let kind = documentKind(head: head) {
            return "This is \(kind), not a video, audio or image file."
        }
        if isISOBaseMedia(head: head) {
            if let missing = missingTopLevelAtom(url, size: size), missing == "moov" {
                return "The recording is incomplete: the file has no index (moov). It was probably interrupted. Re-copy it from the card, or repair it with the camera maker's tool."
            }
            return "The file is damaged or uses a format Sequence Studio cannot read."
        }
        if !knownMediaExtensions.contains(ext) {
            return ext.isEmpty ? "This file has no type Sequence Studio recognizes."
                               : "Files of type .\(ext) are not a media type Sequence Studio recognizes."
        }
        return "The file may be damaged, or uses a format Sequence Studio cannot read."
    }

    /// Codecs that identify a camera RAW format by their four-character code.
    static func codecAdvice(_ codec: String) -> Container? {
        switch codec.trimmingCharacters(in: .whitespaces).lowercased() {
        case "aprn", "aprh":
            return Container(name: "ProRes RAW", advice: "Export it as ProRes 422 or 4444 from the camera's own software (or Final Cut Pro) and import that.")
        case "braw": return Container(name: "Blackmagic RAW (BRAW)", advice: brawAdvice)
        default: return nil
        }
    }

    static let brawAdvice = "Render it to ProRes 422 or 4444 in DaVinci Resolve (the free version works) and import the result."
    static let r3dAdvice = "Render it to ProRes 422 or 4444 with REDCINE-X PRO or DaVinci Resolve and import the result."
    static let dtsAdvice = "Convert it to WAV or AIFF (multichannel is fine) with a tool such as ffmpeg or Audacity and import it again."
    static let dngAdvice = "A CinemaDNG shot is a folder of numbered frames: render it to ProRes 422 or 4444 in DaVinci Resolve and import the result."
    static let legacyVideoAdvice = "Convert it to MP4 (H.264 or HEVC) with HandBrake or ffmpeg and import it again."

    // MARK: Sniffing

    static func readHead(_ url: URL, count: Int) -> [UInt8] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        return Array((try? h.read(upToCount: count)) ?? Data())
    }

    static func container(head: [UInt8], ext: String, stem: String = "") -> Container? {
        let numbered = stem.last?.isNumber == true         // frame of a numbered CinemaDNG shot
        func starts(_ s: String, at o: Int = 0) -> Bool {
            let b = Array(s.utf8)
            return head.count >= o + b.count && Array(head[o..<(o + b.count)]) == b
        }
        let convert = "Convert it to MP4 (H.264 or HEVC) and import it again."
        // RED files carry "RED1"/"RED2" after a 4-byte size.
        if starts("RED1", at: 4) || starts("RED2", at: 4) { return Container(name: "RED R3D", advice: r3dAdvice) }
        if starts("RIFF"), starts("AVI ", at: 8) { return Container(name: "AVI", advice: convert) }
        if head.count >= 4, Array(head[0..<4]) == [0x30, 0x26, 0xB2, 0x75] { return Container(name: "Windows Media (WMV)", advice: legacyVideoAdvice) }
        if starts("FLV") { return Container(name: "Flash Video (FLV)", advice: convert) }
        if starts(".RMF") { return Container(name: "RealMedia", advice: convert) }
        if starts("OggS") { return Container(name: "Ogg", advice: "Convert it to WAV, AIFF or AAC (m4a) and import it again.") }
        if head.count >= 4, Array(head[0..<4]) == [0x00, 0x00, 0x01, 0xBA] { return Container(name: "MPEG program stream (VOB)", advice: convert) }
        switch ext {
        case "avi": return Container(name: "AVI", advice: convert)
        case "wmv", "asf": return Container(name: "Windows Media (WMV)", advice: legacyVideoAdvice)
        case "braw": return Container(name: "Blackmagic RAW (BRAW)", advice: brawAdvice)
        case "r3d": return Container(name: "RED R3D", advice: r3dAdvice)
        case "dts", "dtshd": return Container(name: "DTS audio", advice: dtsAdvice)
        case "dng" where numbered: return Container(name: "CinemaDNG", advice: dngAdvice)
        case "flv", "f4v": return Container(name: "Flash Video (FLV)", advice: convert)
        case "rm", "rmvb": return Container(name: "RealMedia", advice: convert)
        case "vob": return Container(name: "MPEG program stream (VOB)", advice: convert)
        case "wma": return Container(name: "Windows Media Audio (WMA)", advice: "Convert it to WAV, AIFF or AAC (m4a) and import it again.")
        default: return nil
        }
    }

    static func documentKind(head: [UInt8]) -> String? {
        func starts(_ b: [UInt8]) -> Bool { head.count >= b.count && Array(head[0..<b.count]) == b }
        if starts(Array("%PDF".utf8)) { return "a PDF document" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "a zip archive" }
        if starts([0x1F, 0x8B]) { return "a compressed archive" }
        if starts(Array("<?xml".utf8)) || starts(Array("<html".utf8)) || starts(Array("{".utf8)) { return "a text document" }
        return nil
    }

    static func isISOBaseMedia(head: [UInt8]) -> Bool {
        head.count >= 8 && Array(head[4..<8]) == Array("ftyp".utf8)
    }

    /// Walks the top-level atoms of an MP4/MOV; returns "moov" when the file ends without a movie atom (an interrupted
    /// recording), nil when it is present or the walk cannot tell.
    static func missingTopLevelAtom(_ url: URL, size: Int64) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var offset: UInt64 = 0
        let end = UInt64(size)
        var sawMdat = false
        for _ in 0..<4096 {
            guard offset + 8 <= end else { break }
            guard (try? h.seek(toOffset: offset)) != nil, let d = try? h.read(upToCount: 16), d.count >= 8 else { return nil }
            let b = Array(d)
            var len = UInt64(b[0]) << 24 | UInt64(b[1]) << 16 | UInt64(b[2]) << 8 | UInt64(b[3])
            let type = String(decoding: b[4..<8], as: UTF8.self)
            if type == "moov" { return nil }
            if type == "mdat" { sawMdat = true }
            if len == 1, b.count >= 16 {
                len = b[8...15].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            } else if len == 0 {
                len = end - offset                 // runs to the end of the file
            }
            guard len >= 8 else { return nil }
            offset += len
        }
        // The walk reached the end (or went past it, a cut-off atom) without a movie atom.
        return sawMdat || offset >= end ? "moov" : nil
    }

    static let knownMediaExtensions: Set<String> = Set([
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "mxf", "mts", "m2ts", "ts", "mpg", "mpeg", "m2v", "3gp", "3g2",
        "wav", "aif", "aiff", "aifc", "mp3", "m4a", "aac", "caf", "flac", "opus", "ogg", "oga", "ac3", "mka",
    ]).union(StillImage.extensions)
}

/// What the importer noticed about a file that did import: the model asks once after the probe (`take`) and tells the
/// user. Session-only memory, keyed by standardized path.
public enum ImportNotes {
    private static let dropped = Mutex<[String: String]>([:])

    /// The file imported, but its audio uses a codec this Mac cannot decode: it plays as video without sound.
    public static func noteAudioDropped(_ url: URL, codec: String) {
        dropped.withLock { $0[url.standardizedFileURL.path] = codec }
    }

    /// The codec of the audio that was dropped for `url` (once), nil if none.
    public static func takeAudioDropped(_ url: URL) -> String? {
        dropped.withLock { $0.removeValue(forKey: url.standardizedFileURL.path) }
    }
}

/// Import-time check that this Mac has a decoder for a codec whose support varies by machine (AV1 needs an M3 or newer
/// for hardware decode and no software decoder ships everywhere; VP9 depends on the OS). A file that fails here is
/// refused at import with the codec named, instead of importing and showing black frames.
enum VideoDecodability {
    static let checkedCodecs: Set<String> = ["av01", "vp09"]

    static func requireDecodable(_ format: CMFormatDescription) throws {
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
        guard checkedCodecs.contains(codec) else { return }
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                              imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &s)
        if let s { VTDecompressionSessionInvalidate(s) }
        if st == kVTCouldNotFindVideoDecoderErr || st == kVTVideoDecoderUnsupportedDataFormatErr {
            throw MediaError.unsupportedCodec(codec)
        }
    }
}
