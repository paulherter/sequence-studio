import Foundation
import SQCore
import SQMediaTestSupport
import SQText
import Synchronization
import Testing
@testable import SQExport

private let fd = Time(1, 30)

private func textRef(_ s: String) throws -> GeneratorRef {
    try TextGenerator.makeRef(template: TextTemplate(name: s, text: s, style: CaptionPresetLibrary.builtIn.style(for: "title")),
                              animations: nil)
}

private func textClip(_ ref: GeneratorRef, start: Time, duration: Time = Time(1, 1)) -> Clip {
    Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: duration), start: start, generator: ref)
}

private func timeline(_ clips: [Clip]) -> Timeline {
    Timeline(name: "t", format: SequenceFormat(width: 64, height: 32, frameDuration: fd), tracks: [Track(kind: .video, clips: clips)])
}

/// PLAYBACK-PERF "Export layers": export rasterized every text clip's first frame on the serial render path (1.7 ms per
/// frame on the reference project). A background queue now renders each raster shortly before its clip shows.
@Suite struct TextPrewarmAheadTests {
    /// Text spans by output start, earliest first, one per clip; a nested sequence's text counts with its outer clip's span.
    @Test func textSpansAreSortedAndNestedOnesUseTheOuterClip() throws {
        let a = try textRef("A"), b = try textRef("B"), n = try textRef("N")
        let inner = timeline([textClip(n, start: Time(5, 1))])
        var nest = Clip(name: "nest", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: Time(3, 1))
        nest.sequence = inner.id
        let tl = timeline([textClip(b, start: Time(6, 1)), textClip(a, start: Time(1, 1)), nest, textClip(a, start: Time(8, 1))])
        let spans = TimelineFrameSource.textSpans(tl, sequences: [inner.id: inner])
        #expect(spans.map(\.ref) == [a, n, b, a])
        #expect(spans.map(\.range.start) == [Time(1, 1), Time(3, 1), Time(6, 1), Time(8, 1)])
        #expect(spans[1].range.end == Time(5, 1))
    }

    /// Item lanes: a text item with a range warms for its own span on the timeline (clamped to the clip), an item whose
    /// range is empty never; an item without a range keeps the clip's span.
    @Test func aRangedTextItemWarmsForItsOwnSpan() throws {
        let whole = try textRef("W"), late = try textRef("L"), never = try textRef("X"), over = try textRef("O")
        func item(_ ref: GeneratorRef, _ range: TimeRange?) -> GraphicsLayer {
            var l = GraphicsLayer(name: "i", content: .text(ref: ref))
            l.range = range
            return l
        }
        var c = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(2, 1))
        c.graphics = GraphicsDocument(layers: [
            item(whole, nil),
            item(late, TimeRange(start: Time(6, 1), end: Time(8, 1))),
            item(never, TimeRange(start: Time(3, 1), end: Time(3, 1))),
            item(over, TimeRange(start: Time(9, 1), end: Time(20, 1)))])
        let spans = TimelineFrameSource.textSpans(timeline([c]), sequences: [:])
        #expect(spans.map(\.ref) == [whole, late, over])
        #expect(spans.map(\.range) == [TimeRange(start: Time(2, 1), end: Time(12, 1)), TimeRange(start: Time(8, 1), end: Time(10, 1)),
                                       TimeRange(start: Time(11, 1), end: Time(12, 1))])
    }

    /// Monitor and export read one evaluation: the text request of a ranged item carries range-local time and the range's
    /// length, so its In/Out animation is the same picture in both.
    @Test func aRangedTextItemAnimatesOnItsRangeForMonitorAndExport() throws {
        let ref = try textRef("R")
        var l = GraphicsLayer(name: "i", content: .text(ref: ref))
        l.range = TimeRange(start: Time(6, 1), end: Time(8, 1))
        var c = Clip(name: "g", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(2, 1),
                     generator: GeneratorRef(kind: GeneratorRef.graphics, payload: Data()))
        c.graphics = GraphicsDocument(layers: [l])
        let tl = timeline([c])
        // The item's last frame: 0.5 s before its end, 1.5 s into its 2 s range.
        let text = tl.videoLayers(at: Time(19, 2)).filter { $0.clip == l.id }
        #expect(text.count == 1)
        #expect(text.first?.localTime == Time(3, 2))
        #expect(text.first?.clipDuration == Time(2, 1))
        #expect(tl.videoLayers(at: Time(5, 1)).allSatisfy { $0.clip != l.id })   // before its range: not drawn
    }

    /// Each ref is handed out once, when one of its clips starts within the lead; spans already over are skipped (a range
    /// export starting late still warms a ref whose later clip is ahead).
    @Test func advanceHandsOutRefsOnceWithinTheLead() throws {
        let a = try textRef("A"), b = try textRef("B"), c = try textRef("C")
        func span(_ s: Int64, _ r: GeneratorRef) -> TimelineFrameSource.TextSpan {
            TimelineFrameSource.TextSpan(range: TimeRange(start: Time(s, 1), duration: Time(1, 1)), ref: r)
        }
        var cursor = TextPrewarmCursor(spans: [span(0, a), span(3, b), span(5, a), span(6, c), span(7, b)], lead: Time(2, 1))
        #expect(cursor.advance(to: Time(2, 1)) == [b])          // a's first clip is over, b starts within 2 s
        #expect(cursor.advance(to: Time(5, 2)).isEmpty)
        #expect(cursor.advance(to: Time(4, 1)) == [a, c])       // a's second clip, then c
        #expect(cursor.advance(to: Time(9, 1)).isEmpty)          // b already handed out
    }

    /// End to end: rendering a frame before a text clip warms that clip's raster off the render path.
    @Test func exportWarmsTheNextTextBeforeItShows() async throws {
        let ref = try textRef("PREWARM AHEAD \(UUID().uuidString.prefix(6))")
        #expect(!TextGenerator.isCached(ref: ref))
        let bg = UUID()
        let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 32, frameDuration: fd), tracks: [
            Track(kind: .video, clips: [Clip(name: "bg", media: bg, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)]),
            Track(kind: .video, clips: [textClip(ref, start: Time(1, 1))])])
        let src = try TimelineFrameSource(timeline: tl, provider: SolidProvider(colors: [bg: (0, 0, 255)], width: 64, height: 32),
                                          width: 64, height: 32, frameDuration: fd, frameCount: 120)
        _ = try await src.frame(at: 0)
        await src.waitForTextPrewarm()
        #expect(TextGenerator.isCached(ref: ref))
        let profile = await src.stageProfile()
        #expect(profile.textColdLayers == 0)
    }
}
