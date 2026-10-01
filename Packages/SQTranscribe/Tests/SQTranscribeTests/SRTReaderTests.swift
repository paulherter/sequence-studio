import Foundation
import Testing
import SQCore
@testable import SQTranscribe

@Suite struct SRTReaderTests {
    let basic = "1\n00:00:01,000 --> 00:00:03,500\nHello world\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond line one\nsecond line two\n\n"

    @Test func parsesBasicCues() throws {
        let doc = try SRTReader.parse(text: basic)
        #expect(doc.captions.count == 2)
        #expect(doc.captions[0].lines == ["Hello world"])
        #expect(doc.captions[0].range == TimeRange(start: t(1000), end: t(3500)))
        #expect(doc.captions[1].lines == ["Second line one", "second line two"])
        #expect(doc.captions[1].range.start == t(4000))
    }

    @Test func crlfDotsMissingIndicesAndBlankTolerance() throws {
        let s = "\r\n\r\n00:00:01.5 --> 00:00:02.25\r\nA b\r\n\r\n\r\n\r\n00:01:00,000 --> 01:00:00,001\r\nC\r\n"
        let doc = try SRTReader.parse(text: s)
        #expect(doc.captions.count == 2)
        #expect(doc.captions[0].range == TimeRange(start: t(1500), end: t(2250)))
        #expect(doc.captions[1].range == TimeRange(start: t(60_000), end: t(3_600_001)))
    }

    @Test func stripsBasicTags() throws {
        let doc = try SRTReader.parse(text: "1\n00:00:00,000 --> 00:00:01,000\n<i>Hi</i> <b>there</b> <font color=\"red\">you</font>\n")
        #expect(doc.captions[0].lines == ["Hi there you"])
        #expect(doc.transcript.words.map(\.text) == ["Hi", "there", "you"])
    }

    @Test func utf8BOMAndUTF16() throws {
        var d8 = Data([0xEF, 0xBB, 0xBF]); d8.append(Data(basic.utf8))
        #expect(try SRTReader.parse(data: d8).captions.count == 2)
        var d16le = Data([0xFF, 0xFE]); d16le.append(basic.data(using: .utf16LittleEndian)!)
        #expect(try SRTReader.parse(data: d16le).captions.count == 2)
        var d16be = Data([0xFE, 0xFF]); d16be.append(basic.data(using: .utf16BigEndian)!)
        let doc = try SRTReader.parse(data: d16be)
        #expect(doc.captions[0].lines == ["Hello world"])
    }

    @Test func transcriptWordsSpreadProportionally() throws {
        // "ab cdef" over 0..3000 ms: 2 and 4 of 6 chars -> boundary at 1000 ms.
        let doc = try SRTReader.parse(text: "1\n00:00:00,000 --> 00:00:03,000\nab cdef\n")
        let words = doc.transcript.words
        #expect(words.count == 2)
        #expect(words[0].range == TimeRange(start: t(0), end: t(1000)))
        #expect(words[1].range == TimeRange(start: t(1000), end: t(3000)))
        #expect(words.allSatisfy { !$0.isEdited })
        let c = doc.captions[0]
        #expect(c.wordIndices == 0..<2)
        #expect(c.firstWordID == words[0].id && c.lastWordID == words[1].id)
    }

    @Test func captionsIndexAcrossCues() throws {
        let doc = try SRTReader.parse(text: basic)
        #expect(doc.captions[0].wordIndices == 0..<2)
        #expect(doc.captions[1].wordIndices == 2..<8)
        #expect(doc.transcript.words.count == 8)
    }

    @Test func malformedTimestampReportsLine() {
        let s = "1\n00:00:01,000 --> 00:00:02,000\nok\n\n2\n00:00:0x,000 --> 00:00:04,000\nbad\n"
        do {
            _ = try SRTReader.parse(text: s)
            Issue.record("expected throw")
        } catch let e as SRTReader.ParseError {
            #expect(e.line == 6)
        } catch { Issue.record("wrong error") }
    }

    @Test func endBeforeStartThrows() {
        #expect(throws: SRTReader.ParseError.self) {
            _ = try SRTReader.parse(text: "1\n00:00:05,000 --> 00:00:02,000\nx\n")
        }
    }

    @Test func emptyInputGivesNothing() throws {
        let doc = try SRTReader.parse(text: "\n\n")
        #expect(doc.captions.isEmpty && doc.transcript.words.isEmpty)
    }

    @Test func roundTripWithHandWrittenExporterText() throws {
        // Text as SQExport's SRT writer emits it (index, "HH:MM:SS,mmm --> ...", lines, blank line).
        let expected = "1\n00:00:00,500 --> 00:00:02,000\nGuten Tag\n\n2\n00:00:02,000 --> 00:00:04,250\nzusammen,\nwie geht's?\n\n"
        let doc = try SRTReader.parse(text: expected)
        var out = ""
        for (i, c) in doc.captions.enumerated() {
            out += "\(i + 1)\n\(ts(c.range.start)) --> \(ts(c.range.end))\n\(c.lines.joined(separator: "\n"))\n\n"
        }
        #expect(out == expected)
    }

    private func ts(_ time: Time) -> String {
        let ms = time.value * 1000 / time.timescale
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
