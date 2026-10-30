import Testing
import Foundation
import SQCore
@testable import SQExport

@Suite struct ITTWriterTests {
    private func cue(_ lines: [String], _ s: Int64, _ e: Int64) -> SRTCue {
        SRTCue(lines: lines, range: TimeRange(start: Time(s, 1000), end: Time(e, 1000)))
    }

    @Test func rendersTimedTextWithLanguageSortedCuesAndEscapes() {
        let out = ITTWriter.render([cue(["B & <i>", "second"], 3000, 4000), cue(["A"], 1000, 2500)], language: "de-DE", range: .entireSequence)
        #expect(out.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tt "))
        #expect(out.contains("xml:lang=\"de-DE\""))
        #expect(out.contains("ttp:timeBase=\"media\""))
        #expect(out.contains("<p begin=\"00:00:01.000\" end=\"00:00:02.500\" region=\"bottom\" style=\"s1\">A</p>"))
        #expect(out.contains(">B &amp; &lt;i&gt;<br/>second</p>"))
        let a = out.range(of: ">A</p>")!, b = out.range(of: "second</p>")!
        #expect(a.lowerBound < b.lowerBound)
    }

    @Test func clipsToTheRangeAndDropsEmptyCues() {
        let r = TimeRange(start: Time(10, 1), end: Time(20, 1))
        let out = ITTWriter.render([cue(["Out"], 1000, 2000), cue(["Edge"], 9000, 11_000), cue(["  "], 12_000, 13_000), cue(["In"], 15_000, 16_000)],
                                   language: "en", range: .inOut(r))
        #expect(out.contains("begin=\"00:00:00.000\" end=\"00:00:01.000\""))
        #expect(out.contains("begin=\"00:00:05.000\" end=\"00:00:06.000\""))
        #expect(!out.contains(">Out<"))
        #expect(out.components(separatedBy: "<p ").count == 3)
    }

    @Test func writesAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-itt-\(UUID().uuidString).itt")
        defer { try? FileManager.default.removeItem(at: url) }
        try ITTWriter.write([cue(["Hi"], 0, 1000)], language: "en", range: .entireSequence, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8).contains(">Hi</p>"))
    }
}
