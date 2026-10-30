import AppKit
import Testing
@testable import SQEditorSession

@Suite struct PasteMediaTests {
    @Test func routing() {
        typealias P = PasteMedia
        #expect(P.route(target: .project, hasOwnClipData: false, hasFiles: true, hasImage: false) == .importFiles)
        #expect(P.route(target: .timeline, hasOwnClipData: false, hasFiles: false, hasImage: true) == .importImage)
        #expect(P.route(target: .timeline, hasOwnClipData: false, hasFiles: true, hasImage: true) == .importFiles)
        // Our own clips win.
        #expect(P.route(target: .timeline, hasOwnClipData: true, hasFiles: true, hasImage: true) == .ownClipboard)
        // Other panels never import.
        for t in [FocusedEditTarget.graphics, .captions, .effectControls, .keystones, .none] {
            #expect(P.route(target: t, hasOwnClipData: false, hasFiles: true, hasImage: true) == .nothing)
        }
        #expect(P.route(target: .project, hasOwnClipData: false, hasFiles: false, hasImage: false) == .nothing)
    }

    @Test func readsFilesAndImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-paste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.mov")
        try Data([1]).write(to: file)

        let pb = NSPasteboard(name: NSPasteboard.Name("sq.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        #expect(!PasteMedia.read(from: pb).hasMedia)
        pb.writeObjects([file as NSURL])
        #expect(PasteMedia.read(from: pb).fileURLs.map(\.lastPathComponent) == ["a.mov"])

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let tiff = try #require(rep.tiffRepresentation)
        pb.clearContents()
        pb.setData(tiff, forType: .tiff)
        let c = PasteMedia.read(from: pb)
        #expect(c.fileURLs.isEmpty)
        let png = try #require(c.imageData)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func missingFileURLIsIgnored() {
        let pb = NSPasteboard(name: NSPasteboard.Name("sq.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/nonexistent/zzz.mov") as NSURL])
        #expect(!PasteMedia.read(from: pb).hasMedia)
    }

    @Test func imageNamingAndWriting() throws {
        let d = Date(timeIntervalSince1970: 0)
        let first = PasteMedia.imageFileName(date: d)
        #expect(first.hasPrefix("Pasted Image 19") && first.hasSuffix(".png"))
        #expect(PasteMedia.imageFileName(date: d) { $0 == first } == first.replacingOccurrences(of: ".png", with: " 2.png"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try PasteMedia.writeImage(Data([1, 2]), into: dir, date: d)
        let b = try PasteMedia.writeImage(Data([3]), into: dir, date: d)
        #expect(a != b)
        #expect(try Data(contentsOf: a) == Data([1, 2]))
    }
}
