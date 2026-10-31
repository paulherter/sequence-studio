import Foundation
import Testing
@testable import SQLibrary

@MainActor @Suite struct LibraryPreviewPlayerTests {
    let id = LibraryEntryID(folderID: UUID(), relativePath: "a.wav")

    @Test func missingFileGivesMessageNotCrash() {
        let p = LibraryPreviewPlayer()
        p.select(id: id, url: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).wav"), mode: .audio)
        #expect(p.errorMessage != nil)
        #expect(!p.isPlaying && p.player == nil)
        p.togglePlayPause()
        p.skip(by: 5)
        #expect(!p.isPlaying)
    }

    @Test func undecodableFileGetsMessage() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let f = try dir.write("junk.wav", bytes: 64)
        let p = LibraryPreviewPlayer()
        p.select(id: id, url: f, mode: .audio)
        for _ in 0..<100 where p.errorMessage == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(p.errorMessage != nil)
        #expect(!p.isPlaying)
    }

    @Test func imageSelectionHasNoPlayerAndStopClears() {
        let p = LibraryPreviewPlayer()
        p.select(id: id, url: URL(fileURLWithPath: "/x.png"), mode: .image)
        #expect(p.currentItemID == id && p.player == nil && p.errorMessage == nil)
        p.stop()
        #expect(p.currentItemID == nil)
    }

    @Test func videoStartsMutedAudioDoesNot() {
        let p = LibraryPreviewPlayer()
        #expect(p.videoMuted && !p.audioMuted)
    }
}

@Suite struct LibrarySidebarWidthTests {
    @Test func defaultsAndClamps() {
        #expect(LibraryPreviewMath.sidebarWidth(stored: nil, panelWidth: 600) == 136)
        #expect(LibraryPreviewMath.sidebarWidth(stored: 10, panelWidth: 600) == 96)
        #expect(LibraryPreviewMath.sidebarWidth(stored: 900, panelWidth: 2000) == 320)
        #expect(LibraryPreviewMath.sidebarWidth(stored: 300, panelWidth: 400) == 240)
        #expect(LibraryPreviewMath.sidebarWidth(stored: 200, panelWidth: 200) == 96)
        #expect(LibraryPreviewMath.sidebarWidth(stored: .nan, panelWidth: 600) == 136)
    }
}
