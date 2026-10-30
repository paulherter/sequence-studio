import Foundation
import Testing
@testable import SQLibrary

@Suite struct CardImportTests {
    @Test func scanIsRecursiveFlatAndFiltersKinds() throws {
        let t = try TempDir(); defer { t.remove() }
        try t.write("DCIM/100/a.MOV"); try t.write("DCIM/101/deep/b.jpg"); try t.write("c.mp4")
        try t.write("notes.txt"); try t.write("song.wav"); try t.write("DCIM/.hidden.mov"); try t.write("._d.mov")
        let all = CardScanner.scan(t.url)
        #expect(Set(all.map(\.name)) == ["a.MOV", "b.jpg", "c.mp4"])
        #expect(CardScanner.scan(t.url, kinds: [.photo]).map(\.name) == ["b.jpg"])
        #expect(Set(CardScanner.scan(t.url, kinds: [.video]).map(\.name)) == ["a.MOV", "c.mp4"])
    }

    @Test func sortOrders() {
        let d = Date(timeIntervalSince1970: 1000)
        func c(_ n: String, _ s: Int64, _ off: Double) -> CardCandidate {
            CardCandidate(url: URL(fileURLWithPath: "/x/\(n)"), kind: .video, size: s, modified: d.addingTimeInterval(off))
        }
        let items = [c("b.mov", 5, 10), c("a.mov", 9, 30), c("c10.mov", 1, 20), c("c9.mov", 1, 20)]
        #expect(CardSort.newestFirst.apply(items).map(\.name) == ["a.mov", "c9.mov", "c10.mov", "b.mov"])
        #expect(CardSort.oldestFirst.apply(items).map(\.name) == ["b.mov", "c9.mov", "c10.mov", "a.mov"])
        #expect(CardSort.name.apply(items).map(\.name) == ["a.mov", "b.mov", "c9.mov", "c10.mov"])
        #expect(CardSort.size.apply(items).map(\.name) == ["a.mov", "b.mov", "c9.mov", "c10.mov"])
    }

    @Test func volumeDetection() {
        func v(_ p: String, int: Bool, rem: Bool = false, ej: Bool = false, local: Bool = true) -> VolumeFacts {
            VolumeFacts(url: URL(fileURLWithPath: p), isInternal: int, isRemovable: rem, isEjectable: ej, isLocal: local)
        }
        #expect(v("/Volumes/SD", int: false, rem: true, ej: true).isImportSource)
        #expect(v("/Volumes/SSD", int: false).isImportSource)
        #expect(v("/Volumes/Cam", int: true, rem: true).isImportSource)
        #expect(!v("/", int: true).isImportSource)
        #expect(!v("/Volumes/Macintosh HD", int: true).isImportSource)
        #expect(!v("/Volumes/NAS", int: false, local: false).isImportSource)
        #expect(!v("/System/Volumes/Data", int: false).isImportSource)
        #expect(!VolumeFacts(url: URL(fileURLWithPath: "/Volumes/Installer"), isInternal: false, isRemovable: false, isEjectable: true, isDiskImage: true).isImportSource)
    }

    @Test func selection() {
        let order = ["a", "b", "c", "d", "e"]
        var s = CardSelection()
        s.click("b", in: order)
        #expect(s.ids == ["b"])
        s.click("d", in: order, shift: true)
        #expect(s.ids == ["b", "c", "d"])
        s.click("a", in: order, toggle: true)
        #expect(s.ids == ["a", "b", "c", "d"])
        s.click("b", in: order, toggle: true)
        #expect(s.ids == ["a", "c", "d"])
        s.prune(to: ["a", "c"])
        #expect(s.ids == ["a", "c"])
        s.selectAll(order); #expect(s.ids.count == 5)
        s.deselect(["a"]); #expect(s.ids == ["b", "c", "d", "e"])
        s.clear(); #expect(s.ids.isEmpty)
    }

    @Test func uniqueDestination() {
        let f = URL(fileURLWithPath: "/dest")
        let taken: Set<String> = ["/dest/a.mov", "/dest/a 2.mov", "/dest/raw"]
        let t: (URL) -> Bool = { taken.contains($0.path) }
        #expect(CardScanner.uniqueDestination(for: "a.mov", in: f, taken: t).lastPathComponent == "a 3.mov")
        #expect(CardScanner.uniqueDestination(for: "b.mov", in: f, taken: t).lastPathComponent == "b.mov")
        #expect(CardScanner.uniqueDestination(for: "raw", in: f, taken: t).lastPathComponent == "raw 2")
    }

    @Test func copierCopiesWithUniqueNamesAndReportsFailures() throws {
        let src = try TempDir(), dst = try TempDir(); defer { src.remove(); dst.remove() }
        let a = try src.write("100/clip.mov", bytes: 10), b = try src.write("101/clip.mov", bytes: 20)
        let missing = src.url.appendingPathComponent("gone.mov")
        var ticks: [Int] = []
        let r = CardCopier.copy([a, b, missing], to: dst.url.appendingPathComponent("Media")) { done, _ in ticks.append(done) }
        #expect(r.copied.map(\.lastPathComponent) == ["clip.mov", "clip 2.mov"])
        #expect(r.failed == ["gone.mov"])
        #expect(ticks == [0, 1, 2, 3])
        #expect(try Data(contentsOf: r.copied[1]).count == 20)
        #expect(r.copiedSources == [a, b])
        #expect(r.failedSources == [missing])
    }

    @Test func copierRejectsShortCopyAndRemovesIt() throws {
        let src = try TempDir(), dst = try TempDir(); defer { src.remove(); dst.remove() }
        let a = try src.write("a.mov", bytes: 100), b = try src.write("b.mov", bytes: 100)
        let r = CardCopier.copy([a, b], to: dst.url, copyItem: { from, to in
            // Simulates the card being pulled during a.mov: only half arrives, no error.
            let data = try Data(contentsOf: from)
            try (from.lastPathComponent == "a.mov" ? data.prefix(50) : data).write(to: to)
        })
        #expect(r.failedSources == [a])
        #expect(r.copiedSources == [b])
        #expect(!FileManager.default.fileExists(atPath: dst.url.appendingPathComponent("a.mov").path))
    }

    @Test func windowsDrivesOfferCardsAndUSBDisksButNotTheSystemOrInternalDisks() {
        func d(_ root: String, _ kind: DriveFacts.Kind, _ bus: DriveFacts.Bus = .other, system: Bool = false) -> DriveFacts {
            DriveFacts(root: root, kind: kind, bus: bus, isSystem: system)
        }
        #expect(d("E:\\", .removable).isImportSource)                       // SD reader, stick
        #expect(d("F:\\", .fixed, .usb).isImportSource)                     // USB SSD that reports DRIVE_FIXED
        #expect(d("G:\\", .fixed, .sd).isImportSource && d("G:\\", .fixed, .mmc).isImportSource)
        #expect(d("H:\\", .fixed, .firewire).isImportSource)
        #expect(!d("D:\\", .fixed).isImportSource)                          // internal SATA / NVMe disk
        #expect(!d("C:\\", .fixed, .usb, system: true).isImportSource)      // Windows To Go: never the system drive
        #expect(!d("Z:\\", .other).isImportSource)                          // network share, optical
    }

    @Test func driveArrivalsOfferOnlyNewImportSourcesAndReportRemovals() {
        let c = DriveFacts(root: "C:\\", kind: .fixed, isSystem: true)
        let ssd = DriveFacts(root: "F:\\", kind: .fixed, bus: .usb)
        let card = DriveFacts(root: "E:\\", kind: .removable)
        let disk = DriveFacts(root: "D:\\", kind: .fixed)
        var w = DriveArrivals(present: [c, card])                           // there at launch: not offered
        #expect(w.update([c, card]) == .init(added: [], removed: []))
        #expect(w.update([c, card, ssd, disk]) == .init(added: ["F:\\"], removed: []))
        #expect(w.update([c, ssd, disk]) == .init(added: [], removed: ["E:\\"]))
        #expect(w.update([c, ssd, disk, card]) == .init(added: ["E:\\"], removed: []))   // the card again
    }
}
