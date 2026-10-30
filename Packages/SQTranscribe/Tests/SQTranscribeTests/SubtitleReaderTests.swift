import Foundation
import Testing
import SQCore
@testable import SQTranscribe

@Suite struct SubtitleReaderTests {
    func t(_ ms: Int64) -> Time { Time(ms, 1000) }

    let vtt = "\u{FEFF}WEBVTT - demo\r\nKind: captions\r\n\r\nNOTE this is a comment\r\nsecond note line\r\n\r\nSTYLE\r\n::cue { color: red }\r\n\r\nintro\r\n00:01.000 --> 00:03.500 line:90% align:center\r\n<v Bob><i>Hello</i> &amp; <c.yellow>world</c>\r\n\r\n00:00:04.000 --> 00:00:06.000\r\nTwo\r\nlines\r\n"

    @Test func vttBasics() throws {
        let doc = try SubtitleReader.parse(data: Data(vtt.utf8), format: .vtt)
        #expect(doc.captions.count == 2)
        #expect(doc.captions[0].range == TimeRange(start: t(1000), end: t(3500)))
        #expect(doc.captions[0].lines == ["Hello & world"])
        #expect(doc.captions[1].lines == ["Two", "lines"])
        #expect(doc.captions[1].range.start == t(4000))
    }

    @Test func vttMalformedThrows() throws {
        #expect(throws: SubtitleReader.ParseError.self) {
            try SubtitleReader.parseVTT(text: "WEBVTT\n\n00:xx.000 --> 00:02.000\nHi\n")
        }
        #expect(throws: SubtitleReader.ParseError.self) {
            try SubtitleReader.parseVTT(text: "WEBVTT\n\n00:05.000 --> 00:02.000\nHi\n")
        }
        #expect(try SubtitleReader.parseVTT(text: "WEBVTT\n").captions.isEmpty)
    }

    let ass = "[Script Info]\nTitle: x\nPlayResY: 1080\n\n[V4+ Styles]\nFormat: Name, Fontname\nStyle: Default,Arial\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,{\\an8\\b1}Second, with comma\nComment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,ignored\nDialogue: 0,0:00:01.00,0:00:03.25,Default,,0,0,0,,{\\i1}Hello{\\i0}\\Nworld\\hnow\nDialogue: 0,0:00:08.00,0:00:09.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10\n"

    @Test func assBasics() throws {
        let doc = try SubtitleReader.parse(data: Data(ass.utf8), format: .ass)
        #expect(doc.captions.count == 2)
        #expect(doc.captions[0].lines == ["Hello", "world now"])
        #expect(doc.captions[0].range == TimeRange(start: t(1000), end: t(3250)))
        #expect(doc.captions[1].lines == ["Second, with comma"])
        #expect(doc.captions[1].range.end == t(7500))
    }

    @Test func assMalformed() {
        #expect(throws: SubtitleReader.ParseError.self) { try SubtitleReader.parseASS(text: "just some text") }
        let bad = "[Events]\nFormat: Start, End, Text\nDialogue: nope,0:00:01.00,Hi\n"
        #expect(throws: SubtitleReader.ParseError.self) { try SubtitleReader.parseASS(text: bad) }
        let noFormat = "[Events]\nDialogue: 0:00:00.00,0:00:01.00,Hi\n"
        #expect(throws: SubtitleReader.ParseError.self) { try SubtitleReader.parseASS(text: noFormat) }
    }

    @Test func formatByExtension() {
        #expect(SubtitleReader.format(forExtension: "VTT") == .vtt)
        #expect(SubtitleReader.format(forExtension: "ssa") == .ass)
        #expect(SubtitleReader.format(forExtension: "mov") == nil)
    }
}
