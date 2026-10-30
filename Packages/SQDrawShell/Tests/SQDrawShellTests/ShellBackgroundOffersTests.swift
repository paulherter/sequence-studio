import Foundation
import Testing
import SQCore
import SQEditorSession
import SQExport
@testable import SQDrawShell

@MainActor
@Suite(.serialized) struct ShellBackgroundOffersTests {
    @Test func offerTextNamesFoundOfTotal() {
        #expect(ShellRelinkOffer.text(found: 4, total: 4) == "Found 4 offline files · Reconnect")
        #expect(ShellRelinkOffer.text(found: 2, total: 5) == "Found 2 of 5 offline files · Reconnect")
    }

    @Test func offerFindsTheFilesInARememberedFolderAndTheClickReconnects() async throws {
        let locate = ShellLocateTests()
        let (h, _, _) = try locate.host()
        let defaults = try #require(UserDefaults(suiteName: "sq-offer-\(UUID().uuidString)"))
        defaults.set([locate.dir.path], forKey: ShellHost.relinkFoldersKey)
        h.startDefaults = defaults
        var status: [String] = []
        h.onStatus = { status.append($0) }
        #expect(h.session.missingMedia.count == 2)
        h.offerRelinkIfNeeded()
        for _ in 0..<600 where h.relinkOffer == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let offer = try #require(h.relinkOffer)
        #expect(offer.text == "Found 2 offline files · Reconnect")
        h.acceptRelinkOffer()
        #expect(h.relinkOffer == nil)
        #expect(h.session.missingMedia.isEmpty)
        #expect(status.last == "Reconnected 2 media files.")
    }

    @Test func mediaBesideACopiedProjectLinksQuietlyWithoutAChip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sq-near-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Files/Imported/C2171.MP4")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 4).write(to: file)
        var p = Project(name: "P")
        p.add(MediaRef(name: "C2171.MP4", path: "/Users/me/Oppo/Files/Imported/C2171.MP4", fingerprint: MediaFingerprint(size: 4)))
        let h = ShellHost(session: EditorSession(project: p, fileURL: root.appendingPathComponent("P.sqproj")), map: .premiereDefault)
        var status: [String] = []
        h.onStatus = { status.append($0) }
        h.offerRelinkIfNeeded()
        for _ in 0..<600 where !h.session.missingMedia.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(h.session.missingMedia.isEmpty)
        #expect(status == ["Reconnected 1 media file."])
        #expect(h.relinkOffer == nil)
        #expect(!h.session.canUndo)
    }

    @Test func noOfferWhenNothingIsOffline() {
        let h = ShellHost(session: EditorSession(project: Project(name: "P")), map: .premiereDefault)
        h.offerRelinkIfNeeded()
        #expect(h.relinkOffer == nil)
        h.acceptRelinkOffer()                      // no offer: nothing happens
    }

    @Test func ringProgressCountsFinishedJobsWholeAndEndsWhenNoneIsOpen() {
        let url = URL(fileURLWithPath: "/tmp/x.mp4")
        func job(_ s: ExportJobState, _ p: Double) -> (state: ExportJobState, progress: Double) { (s, p) }
        #expect(ShellHost.overallProgress([]) == nil)
        #expect(ShellHost.overallProgress([job(.running, 0.5), job(.waiting, 0)]) == 0.25)
        #expect(ShellHost.overallProgress([job(.done(url), 1), job(.running, 0.5)]) == 0.75)
        #expect(ShellHost.overallProgress([job(.done(url), 1), job(.failed("x"), 0)]) == nil)
    }
}
