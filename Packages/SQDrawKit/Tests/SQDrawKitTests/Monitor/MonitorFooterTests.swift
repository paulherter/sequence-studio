import Foundation
import SQCore
import SQUIKit
import Testing
@testable import SQDrawKit

@Suite("MonitorFooter")
struct MonitorFooterTests {
    let fd = Time(1, 25)
    /// 100 frames over a 224 pt strip: track 12...212, 2 pt per frame.
    func state(in i: Int64? = nil, out o: Int64? = nil, at t: Int64 = 0) -> MonitorFooterState {
        var s = MonitorFooterState(mode: .program, frameDuration: fd)
        s.duration = fd * 100; s.currentTime = fd * t
        s.markIn = i.map { fd * $0 }; s.markOut = o.map { fd * $0 }
        return s
    }
    func footer(_ s: MonitorFooterState, width: CGFloat = 224) -> MonitorFooter {
        var f = MonitorFooter()
        f.layout(CGRect(x: 0, y: 0, width: width, height: MonitorFooter.height), s, durationWidth: 70)
        return f
    }
    func y(_ f: MonitorFooter) -> CGFloat { f.scrubRect.midY }

    @Test func dragOnEmptyTrackMarksNewRangeAndCommitsOnce() {
        let s = state(at: 90)
        var f = footer(s)
        #expect(f.mouseDown(CGPoint(x: 32, y: y(f)), s).isEmpty)                      // pending at frame 10
        #expect(f.mouseDragged(CGPoint(x: 34, y: y(f)), s).isEmpty)                   // under the 3 pt threshold
        #expect(f.mouseDragged(CGPoint(x: 52, y: y(f)), s) == [.previewRange(markIn: fd * 10, markOut: fd * 21)])
        #expect(f.mouseUp(CGPoint(x: 52, y: y(f)), s) == [.commitRange(.newRange)])
    }

    @Test func gripDragPreviewsThatMarkAndClickSeeks() {
        let s = state(in: 20, out: 60, at: 90)
        var f = footer(s)
        #expect(f.mouseDown(CGPoint(x: 53, y: y(f)), s) == [.previewMark(.markIn, fd * 21)])
        #expect(f.mouseDragged(CGPoint(x: 62, y: y(f)), s) == [.previewMark(.markIn, fd * 25)])
        #expect(f.mouseUp(CGPoint(x: 62, y: y(f)), s) == [.commitMark(.markIn)])
        // Inside the range: moves it, same length.
        _ = f.mouseDown(CGPoint(x: 92, y: y(f)), s)
        #expect(f.mouseDragged(CGPoint(x: 102, y: y(f)), s) == [.previewRange(markIn: fd * 25, markOut: fd * 65)])
        #expect(f.mouseUp(CGPoint(x: 102, y: y(f)), s) == [.commitRange(.body)])
        // A click on empty track outside the range seeks there.
        _ = f.mouseDown(CGPoint(x: 172, y: y(f)), s)
        #expect(f.mouseUp(CGPoint(x: 172, y: y(f)), s) == [.scrubBegan, .scrub(fd * 80), .scrubEnded])
    }

    @Test func sourceFileViewDragScrubsInsteadOfMarking() {
        var s = state(at: 0); s.sourceFileView = true; s.marksEditable = false
        var f = footer(s)
        _ = f.mouseDown(CGPoint(x: 112, y: y(f)), s)
        #expect(f.mouseDragged(CGPoint(x: 122, y: y(f)), s) == [.scrubBegan, .scrub(fd * 55)])
        #expect(f.mouseUp(CGPoint(x: 122, y: y(f)), s) == [.scrubEnded])
        #expect(MonitorFooter.markMenu(s)[0]!.enabled == false)
    }

    @Test func transportCenteredButtonsFireOnReleaseAndNarrowDropsDuration() {
        let s = state()
        var f = footer(s, width: 600)
        #expect(f.buttons.map(\.0) == MonitorAction.buttonBar(for: .program))
        let play = f.buttons.first { $0.0 == .playPause }!.1
        #expect(abs(play.midX - 300) <= 1)
        let p = CGPoint(x: play.midX, y: play.midY)
        _ = f.mouseDown(p, s)
        #expect(f.mouseUp(p, s) == [.action(.playPause)])
        #expect(f.durationRect.width == 70)
        #expect(footer(s, width: 300).durationRect.width == 0)
        var src = MonitorFooterState(mode: .source, frameDuration: fd); src.duration = fd * 10
        #expect(footer(src, width: 600).buttons.map(\.0).suffix(2).sorted { "\($0)" < "\($1)" } == [.insert, .overwrite])
        #expect(src.footerDurationText == src.timecode.format(fd * 10))
    }

    @Test func drawsPlayheadBandAndGrips() {
        let s = state(in: 20, out: 60, at: 90)
        let f = footer(s)
        let t = DrawTheme()
        var c = Canvas(width: 224, height: Float(MonitorFooter.height), atlas: nil, scale: 1)
        f.drawScrubBar(&c, s, theme: t)
        let img = SoftwareRenderer.render(c.list, width: 224, height: 66, clear: .black, atlas: nil)
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(img.pixels[(y * 224 + x) * 4..<(y * 224 + x) * 4 + 3]) }
        #expect(px(192, 8 + 8)[0] > 200)            // playhead at frame 90 (x 192), white
        #expect(px(100, 8 + 6) != [0, 0, 0])       // In-Out band
        #expect(px(5, 8 + 8) == [0, 0, 0])         // outside the track inset
    }

    /// The Mac `TimecodeField`: a drag past 3 pt scrubs 1 frame per 2 pt from the time at the press; a click opens the
    /// field with the position selected, Return answers the typed text, Esc closes it without an answer.
    @Test func theTimecodeDragsToScrubAndAClickOpensTheField() {
        let s = state(at: 50)
        var f = footer(s)
        let tc = CGPoint(x: f.timecodeRect.midX, y: f.timecodeRect.midY)
        #expect(f.mouseDown(tc, s).isEmpty)
        #expect(f.mouseDragged(CGPoint(x: tc.x + 2, y: tc.y), s).isEmpty)
        #expect(f.mouseDragged(CGPoint(x: tc.x + 20, y: tc.y), s) == [.scrubBegan, .scrub(fd * 60)])
        #expect(f.mouseDragged(CGPoint(x: tc.x - 200, y: tc.y), s) == [.scrub(.zero)])   // never before 0
        #expect(f.mouseUp(CGPoint(x: tc.x - 200, y: tc.y), s) == [.scrubEnded])
        #expect(!f.isEditingTimecode)
        _ = f.mouseDown(tc, s)
        #expect(f.mouseUp(tc, s).isEmpty)
        #expect(f.timecodeEdit?.string == s.timecode.position(s.currentTime))
        #expect(f.timecodeEdit?.selection == 0..<(f.timecodeEdit?.text.count ?? 0))
        #expect(f.timecodeKey(.character("1"), modifiers: []) == [])
        #expect(f.timecodeKey(.character("0"), modifiers: []) == [])
        #expect(f.timecodeKey(.enter, modifiers: []) == [.commitTimecode("10")])
        #expect(!f.isEditingTimecode)
        #expect(f.timecodeKey(.enter, modifiers: []) == nil)              // closed: keys are not the field's
        f.beginTimecodeEdit(s)
        #expect(f.timecodeKey(.escape, modifiers: []) == [])
        #expect(!f.isEditingTimecode)
    }

    @Test func aClickInTheOpenFieldPlacesTheCaretAndAPressElsewhereClosesIt() {
        let s = state(at: 50)
        var f = footer(s)
        f.beginTimecodeEdit(s)
        let carets = MonitorFooter.timecodeCarets(f.timecodeEdit!.string) { CGFloat($0.count * 7) }
        _ = f.mouseDown(CGPoint(x: f.timecodeRect.minX + 15, y: f.timecodeRect.midY), s) { MonitorFooter.caretIndex(at: $0, carets: carets) }
        #expect(f.timecodeEdit?.caret == 2 && f.timecodeEdit?.hasSelection == false)
        var c = Canvas(width: 300, height: 100, atlas: nil, scale: 1)
        f.draw(&c, s, theme: DrawTheme())
        _ = f.mouseDown(CGPoint(x: f.scrubRect.midX, y: y(f)), s)
        #expect(!f.isEditingTimecode)
    }
}
