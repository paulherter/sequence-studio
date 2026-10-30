import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SQMedia

private func tmp(_ name: String, _ data: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SQDiag-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent(name)
    try data.write(to: u)
    return u
}

private func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    let n = UInt32(8 + payload.count)
    return [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + Array(type.utf8) + payload
}

@Suite("Media diagnosis")
struct MediaDiagnosisTests {
    @Test func missingFile() {
        let r = MediaDiagnosis.reason(for: URL(fileURLWithPath: "/nonexistent/clip.mp4"))
        #expect(r.contains("no longer there"))
    }

    @Test func emptyFile() throws {
        let u = try tmp("a.mp4", Data())
        #expect(MediaDiagnosis.reason(for: u).contains("empty"))
    }

    @Test func aviIsNamed() throws {
        var d = Data("RIFF".utf8); d.append(contentsOf: [0, 0, 0, 0]); d.append(Data("AVI LIST".utf8))
        let u = try tmp("clip.avi", d)
        let r = MediaDiagnosis.reason(for: u)
        #expect(r.contains("AVI"))
        #expect(r.contains("Convert"))
    }

    @Test func interruptedRecordingHasNoMoov() throws {
        let bytes = box("ftyp", Array("isom".utf8) + [0, 0, 0, 0] + Array("isom".utf8)) + box("mdat", [UInt8](repeating: 7, count: 400))
        let u = try tmp("rec.mp4", Data(bytes))
        #expect(MediaDiagnosis.reason(for: u).contains("moov"))
    }

    @Test func pdfNamedAsMovie() throws {
        let u = try tmp("fake.mov", Data("%PDF-1.4 xxxxxxxxxxxx".utf8))
        #expect(MediaDiagnosis.reason(for: u).contains("PDF"))
    }

    @Test func unsupportedCodecNamed() throws {
        let u = try tmp("a.mkv", Data([1, 2, 3]))
        let r = MediaDiagnosis.reason(for: u, error: MediaError.unsupportedCodec("av01"))
        #expect(r.contains("av01"))
    }

    @Test(arguments: [
        ("clip.braw", "Blackmagic RAW", "DaVinci Resolve"),
        ("A001_C002.R3D", "RED R3D", "REDCINE-X"),
        ("movie.wmv", "Windows Media", "HandBrake"),
        ("mix.dts", "DTS", "WAV"),
        ("mix.dtshd", "DTS", "WAV"),
        ("shot_00012.dng", "CinemaDNG", "ProRes"),
    ])
    func rawAndLegacyFormatsGetFriendlyAdvice(file: String, name: String, tool: String) throws {
        let u = try tmp(file, Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]))
        let r = MediaDiagnosis.reason(for: u)
        #expect(r.contains(name), "\(r)")
        #expect(r.contains(tool), "\(r)")
        #expect(r.contains("not supported"), "\(r)")
    }

    @Test func singlePhotoDNGIsNotCalledCinemaDNG() throws {
        let u = try tmp("IMG_0001x.dng", Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]))
        #expect(!MediaDiagnosis.reason(for: u).contains("CinemaDNG"))
    }

    @Test func proResRawCodecIsNamedWithAdvice() throws {
        let u = try tmp("a.mov", Data([1, 2, 3]))
        for code in ["aprn", "aprh"] {
            let r = MediaDiagnosis.reason(for: u, error: MediaError.unsupportedCodec(code))
            #expect(r.contains("ProRes RAW") && r.contains("ProRes 422"), "\(r)")
        }
        #expect(MediaDiagnosis.reason(for: u, error: MediaError.unsupportedCodec("braw ")).contains("Blackmagic RAW"))
    }

    @Test func redFileIsRecognizedByItsHeader() throws {
        var d = Data([0, 0, 0, 0x20]); d.append(Data("RED2".utf8)); d.append(Data(count: 24))
        let u = try tmp("noext", d)
        #expect(MediaDiagnosis.reason(for: u).contains("RED R3D"))
    }

    @Test func importNotesAreTakenOnce() {
        let u = URL(fileURLWithPath: "/tmp/notes-\(UUID().uuidString).webm")
        ImportNotes.noteAudioDropped(u, codec: "ac-3")
        #expect(ImportNotes.takeAudioDropped(u) == "ac-3")
        #expect(ImportNotes.takeAudioDropped(u) == nil)
    }
}

@Suite("Still formats")
struct StillFormatTests {
    @Test func extensionsCoverNewFormats() {
        for e in ["psd", "exr", "tga", "dng", "cr3", "nef", "arw", "svg", "pdf", "ai"] {
            #expect(StillImage.extensions.contains(e), "\(e)")
        }
    }

    @Test func tgaDecodes() throws {
        // 2x2 uncompressed 32-bit TGA.
        var h = [UInt8](repeating: 0, count: 18)
        h[2] = 2; h[12] = 2; h[14] = 2; h[16] = 32; h[17] = 8 | 0x20
        let px: [UInt8] = [255, 0, 0, 255,  0, 255, 0, 255,  0, 0, 255, 255,  255, 255, 255, 255]
        let u = try tmp("a.tga", Data(h + px))
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            return   // this OS build has no TGA reader; the importer reports the file as unreadable
        }
        let s = try StillImage.size(of: u)
        #expect(s.width == 2 && s.height == 2)
    }

    @Test func pdfRendersFirstPageAtImportSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SQPdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("logo.pdf")
        var media = CGRect(x: 0, y: 0, width: 200, height: 100)
        let ctx = try #require(CGContext(u as CFURL, mediaBox: &media, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()

        let s = try StillImage.size(of: u)
        #expect(s.width == StillImage.vectorMinimumSide)
        #expect(s.height == StillImage.vectorMinimumSide / 2)
        let img = try StillImage.cgImage(of: u)
        #expect(img.width == s.width && img.height == s.height)
        let small = try StillImage.cgImage(of: u, fitHeight: 50)
        #expect(small.height == 50)
        let pb = try StillImage.load(u)
        #expect(CVPixelBufferGetWidth(pb) == s.width)
    }

    @Test func brokenPdfIsUnreadable() throws {
        let u = try tmp("x.pdf", Data("not a pdf".utf8))
        #expect(throws: StillImage.StillError.self) { _ = try StillImage.size(of: u) }
    }
}

@Suite("Video decodability")
struct VideoDecodabilityTests {
    private func format(_ codec: CMVideoCodecType) throws -> CMFormatDescription {
        var fd: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: 1920, height: 1080, extensions: nil, formatDescriptionOut: &fd)
        return try #require(fd)
    }

    @Test func uncheckedCodecsPass() throws {
        try VideoDecodability.requireDecodable(format(kCMVideoCodecType_H264))
    }

    @Test func checkedCodecsEitherPassOrNameTheCodec() throws {
        for codec in [kCMVideoCodecType_VP9, kCMVideoCodecType_AV1] {
            do { try VideoDecodability.requireDecodable(format(codec)) }
            catch MediaError.unsupportedCodec(let name) { #expect(VideoDecodability.checkedCodecs.contains(name)) }
        }
    }
}
