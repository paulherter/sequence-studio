import Foundation
import Testing
@testable import SSLibrary

@Suite struct LibraryItemKindTests {
    @Test(arguments: [
        ("a.mp4", LibraryItemKind.video), ("a.MOV", .video), ("a.mkv", .video), ("a.m4v", .video),
        ("a.wav", .audio), ("a.MP3", .audio), ("a.aiff", .audio), ("a.m4a", .audio), ("a.flac", .audio),
        ("a.png", .image), ("a.JPG", .image), ("a.heic", .image), ("a.tiff", .image),
        ("a.cube", .lut), ("a.3dl", .lut), ("a.CUBE", .lut),
        ("a.ttf", .font), ("a.otf", .font), ("a.ttc", .font),
        ("a.txt", .other), ("noextension", .other), ("a.pdf", .other),
    ])
    func classifiesByExtension(name: String, expected: LibraryItemKind) {
        #expect(LibraryItemKind.classify(URL(fileURLWithPath: "/x/\(name)")) == expected)
    }

    @Test func alphaPromotesVideoAndImageToOverlay() {
        let mov = URL(fileURLWithPath: "/x/a.mov")
        let png = URL(fileURLWithPath: "/x/a.png")
        let wav = URL(fileURLWithPath: "/x/a.wav")
        #expect(LibraryItemKind.classify(mov, hasAlpha: true) == .overlay)
        #expect(LibraryItemKind.classify(png, hasAlpha: true) == .overlay)
        #expect(LibraryItemKind.classify(wav, hasAlpha: true) == .audio)
        #expect(LibraryItemKind.classify(mov, hasAlpha: false) == .video)
    }

    @Test func hiddenAndSystemFilesAreIgnored() {
        for name in [".DS_Store", ".hidden.mp4", "._clip.mov", "Thumbs.db", "desktop.ini", ".localized"] {
            #expect(LibraryItemKind.isIgnored(fileName: name), "\(name)")
        }
        #expect(!LibraryItemKind.isIgnored(fileName: "clip.mov"))
        #expect(LibraryItemKind.classifyIfVisible(URL(fileURLWithPath: "/x/.DS_Store")) == nil)
        #expect(LibraryItemKind.classifyIfVisible(URL(fileURLWithPath: "/x/a.mov")) == .video)
    }
}
