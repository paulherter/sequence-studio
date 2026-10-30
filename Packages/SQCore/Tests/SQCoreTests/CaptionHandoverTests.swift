import Foundation
import Testing
@testable import SQCore

/// Two captions that touch (or sit up to two frames apart) hand over without a blank frame; a caption on its own keeps
/// its whole in and out (maintainer bug 2026-10-08).
@Suite struct CaptionHandoverTests {
    let fd = Time(1, 30)
    func f(_ n: Int64) -> Time { fd * n }
    func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: f(a), end: f(b)) }

    @Test func touchingRangesHandOver() {
        #expect(CaptionHandover.handsOver(r(0, 10), to: r(10, 20), frameDuration: fd))
        #expect(CaptionHandover.handsOver(r(0, 10), to: r(12, 20), frameDuration: fd))
        #expect(!CaptionHandover.handsOver(r(0, 10), to: r(13, 20), frameDuration: fd))
        #expect(!CaptionHandover.handsOver(r(0, 10), to: r(9, 20), frameDuration: fd))       // overlapping: never
        // Without a frame duration only captions that touch exactly hand over.
        #expect(CaptionHandover.handsOver(r(0, 10), to: r(10, 20), frameDuration: .zero))
        #expect(!CaptionHandover.handsOver(r(0, 10), to: r(11, 20), frameDuration: .zero))
        // A gap just above two frames on another time base is no hand-over; exactly two frames is.
        let a = TimeRange(start: .zero, end: Time(1001, 30000))
        #expect(CaptionHandover.handsOver(a, to: TimeRange(start: a.end + Time(2, 30), end: Time(2, 1)), frameDuration: fd))
        #expect(!CaptionHandover.handsOver(a, to: TimeRange(start: a.end + Time(2001, 30000), end: Time(2, 1)), frameDuration: fd))
    }

    @Test func resolveExtendsThroughASmallGapAndNamesTheTail() {
        // Alone: its own range, half-open.
        #expect(CaptionHandover.resolve(previous: nil, current: r(10, 20), next: nil, at: f(9), frameDuration: fd) == nil)
        #expect(CaptionHandover.resolve(previous: nil, current: r(10, 20), next: nil, at: f(20), frameDuration: fd) == nil)
        let alone = CaptionHandover.resolve(previous: r(0, 7), current: r(10, 20), next: r(23, 30), at: f(10), frameDuration: fd)
        #expect(alone == .init(duration: f(10), held: false, tailDuration: nil))
        // Touching neighbors: same duration, the caption before is the tail.
        let touching = CaptionHandover.resolve(previous: r(2, 10), current: r(10, 20), next: r(20, 30), at: f(10), frameDuration: fd)
        #expect(touching == .init(duration: f(10), held: false, tailDuration: f(8)))
        // Two frames apart: the caption runs to the next start and holds in the gap.
        let gap = CaptionHandover.resolve(previous: r(0, 8), current: r(10, 20), next: r(22, 30), at: f(21), frameDuration: fd)
        #expect(gap == .init(duration: f(12), held: true, tailDuration: f(10)))
        #expect(CaptionHandover.resolve(previous: nil, current: r(10, 20), next: r(22, 30), at: f(22), frameDuration: fd) == nil)
        #expect(CaptionHandover.resolve(previous: nil, current: r(10, 20), next: r(23, 30), at: f(20), frameDuration: fd) == nil)
    }

    @Test func entranceCoverageFollowsTheInAnimation() throws {
        let fade = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)])],
                                    duration: Time(1, 5))
        let set = try #require(AnimationSet(single: fade))
        #expect(set.entranceCoverage(clipTime: .zero) { nil } == 0)
        #expect(abs(set.entranceCoverage(clipTime: Time(1, 10)) { nil } - 0.5) < 1e-9)
        #expect(set.entranceCoverage(clipTime: Time(1, 1)) { nil } == 1)
        // Scale from zero: nothing on the first frame, all of it as soon as it has a size.
        let pop = KeyframeTemplate(tracks: [AnimationTrack(property: "scale", keys: [(.zero, 0, .easeOut), (f(4), 1.2, .linear)])],
                                   duration: f(4))
        let popSet = try #require(AnimationSet(single: pop))
        #expect(popSet.entranceCoverage(clipTime: .zero) { nil } == 0)
        #expect(popSet.entranceCoverage(clipTime: f(1)) { nil } == 1)
        // An out look, a loop and a start that is not hidden cover from the first frame.
        var out = fade; out.anchor = .end
        #expect(AnimationSet(single: out)?.entranceCoverage(clipTime: .zero) { nil } == 1)
        var loop = fade; loop.loops = true
        #expect(AnimationSet(single: loop)?.entranceCoverage(clipTime: .zero) { nil } == 1)
        let slide = KeyframeTemplate(tracks: [AnimationTrack(property: "positionY", keys: [(.zero, 80, .linear), (f(6), 0, .linear)])],
                                     duration: f(6))
        #expect(AnimationSet(single: slide)?.entranceCoverage(clipTime: .zero) { nil } == 1)
    }

    /// An in look that is still zero one frame in steps on to the first frame that draws, at most three frames; else one.
    @Test func enteringClipTimeStepsToTheFirstVisibleFrameWithinThree() throws {
        func inSet(hiddenUntil: Time) throws -> AnimationSet {
            let t = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [
                (.zero, 0, .linear), (hiddenUntil, 0, .linear), (hiddenUntil + Time(1, 5), 1, .linear)])],
                                     duration: hiddenUntil + Time(1, 5))
            return try #require(AnimationSet(single: t))
        }
        var out = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 5), 0, .linear)])],
                                   duration: Time(1, 5))
        out.anchor = .end
        let prev = AnimationSet(single: out)
        func shifted(_ entering: AnimationSet, from t: Time = .zero) -> Time {
            CaptionHandover.enteringClipTime(previous: prev, entering: entering, clipTime: t, frameDuration: fd) { nil }
        }
        #expect(shifted(try inSet(hiddenUntil: Time(1, 100))) == fd)       // visible one frame in
        #expect(shifted(try inSet(hiddenUntil: fd)) == fd * 2)              // zero at one frame, visible at two
        #expect(shifted(try inSet(hiddenUntil: fd * 2)) == fd * 3)
        #expect(shifted(try inSet(hiddenUntil: fd * 3)) == fd)              // zero through three frames: keep one
        #expect(shifted(try inSet(hiddenUntil: fd * 30)) == fd)
        // Frames still hidden before the first visible one are held there; a visible frame is untouched.
        #expect(shifted(try inSet(hiddenUntil: fd * 2), from: fd) == fd * 3)
        #expect(shifted(try inSet(hiddenUntil: fd * 2), from: fd * 2) == fd * 3)
        #expect(shifted(try inSet(hiddenUntil: fd * 2), from: fd * 3) == fd * 3)
        #expect(shifted(try inSet(hiddenUntil: fd * 3), from: fd) == fd)        // beyond the cap: frame 0 only
        #expect(shifted(try inSet(hiddenUntil: fd * 3), from: fd * 2) == fd * 2)
        // Not a hand-over, or visible from the start: untouched.
        #expect(CaptionHandover.enteringClipTime(previous: nil, entering: try inSet(hiddenUntil: fd), clipTime: .zero,
                                                 frameDuration: fd) { nil } == .zero)
        let shown = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0.5, .linear), (Time(1, 5), 1, .linear)])],
                                     duration: Time(1, 5))
        #expect(shifted(try #require(AnimationSet(single: shown))) == .zero)
    }

    /// `draw` is `enteringClipTime` then `tailOpacity`: the one request monitor and export burn-in share. A delay past
    /// the three-frame cap is the author's: nothing is held, the stretch stays empty.
    @Test func drawIsTheShiftedTimeAndTheTailOpacity() throws {
        var out = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 5), 0, .linear)])],
                                   duration: Time(1, 5))
        out.anchor = .end
        let fadeIn = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)])],
                                      duration: Time(1, 5))
        let inSet = try #require(AnimationSet(single: fadeIn))
        let outSet = AnimationSet(single: out)
        // After an out look the first frame steps one frame in; the old caption is gone (opacity factor 0).
        let a = CaptionHandover.draw(previous: outSet, entering: inSet, naturalClipTime: .zero, frameDuration: fd) { nil }
        #expect(a.clipTime == fd && a.tailOpacity == 0)
        // After a caption without an out look the time is natural and the tail fills what the fade has not covered.
        let still = AnimationSet(single: KeyframeTemplate(tracks: [], duration: .zero))
        let b = CaptionHandover.draw(previous: still, entering: inSet, naturalClipTime: fd * 2, frameDuration: fd) { nil }
        #expect(b.clipTime == fd * 2)
        #expect(b.tailOpacity == CaptionHandover.tailOpacity(previous: still, entering: inSet, clipTime: fd * 2) { nil })
        #expect(b.tailOpacity > 0 && b.tailOpacity < 1)
        // Past the in-animation: no tail.
        let c = CaptionHandover.draw(previous: still, entering: inSet, naturalClipTime: Time(1, 2), frameDuration: fd) { nil }
        #expect(c == .init(clipTime: Time(1, 2), tailOpacity: 0))
        // Hidden past the cap (4 frames): only frame 0 shifts by one frame, the rest keeps its natural time.
        let late = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [
            (.zero, 0, .linear), (fd * 4, 0, .linear), (fd * 4 + Time(1, 5), 1, .linear)])], duration: fd * 4 + Time(1, 5))
        let lateSet = try #require(AnimationSet(single: late))
        for n in 0..<4 {
            let d = CaptionHandover.draw(previous: outSet, entering: lateSet, naturalClipTime: fd * Int64(n), frameDuration: fd) { nil }
            #expect(d.clipTime == (n == 0 ? fd : fd * Int64(n)))
        }
    }

    /// Frame by frame (off the grid too): no hidden frame after a visible one, and none at all up to a delay of two frames.
    @Test func handoverFramesNeverFlashAfterADelayedInLook() throws {
        var out = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 5), 0, .linear)])],
                                   duration: Time(1, 5))
        out.anchor = .end
        let prev = AnimationSet(single: out)
        for delay in Int64(0)...3 {
            let hidden = fd * delay
            let t = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [
                (.zero, 0, .linear), (hidden + Time(1, 1000), 0, .linear), (hidden + Time(1, 5), 1, .linear)])],
                                     duration: hidden + Time(1, 5))
            let set = try #require(AnimationSet(single: t))
            for offset in [Time.zero, Time(1, 90)] {
                var seen = false
                for n in 0..<10 {
                    let natural = offset + fd * Int64(n)
                    let c = set.entranceCoverage(clipTime: CaptionHandover.enteringClipTime(
                        previous: prev, entering: set, clipTime: natural, frameDuration: fd) { nil }) { nil }
                    if seen { #expect(c > 0, "delay \(delay) offset \(offset) frame \(n): flash") }
                    if c > 0 { seen = true }
                    if delay <= 2 { #expect(c > 0, "delay \(delay) offset \(offset) frame \(n): empty") }
                }
                #expect(seen)
            }
        }
    }

    @Test func entranceCoverageOfATextAnimatorIsAllOrNothing() throws {
        let units = TextUnits.segment(text: "one two", lines: [NSRange(location: 0, length: 7)])
        #expect(units.wordCount == 2)
        func cover(_ effect: TextAnimatorEffect, duration: Time = Time(3, 10), at t: Time) throws -> Double {
            let anim = TextAnimator(effect: effect, unit: .word, duration: duration, stagger: Time(1, 10))
            return try #require(AnimationSet(single: KeyframeTemplate(textAnimator: anim))).entranceCoverage(clipTime: t) { units }
        }
        for effect in [TextAnimatorEffect.fade, .pop, .slide, .blur] {
            #expect(try cover(effect, at: .zero) == 0, "\(effect)")
            #expect(try cover(effect, at: f(1)) == 1, "\(effect)")          // the first word shows: the block is there
            #expect(try cover(effect, at: Time(2, 1)) == 1, "\(effect)")
        }
        // A typewriter without a fade shows its first unit on the first frame.
        #expect(try cover(.typewriter, duration: .zero, at: .zero) == 1)
        // Without units (no layout yet) only the block counts.
        let anim = TextAnimator(effect: .fade, unit: .word, duration: Time(3, 10), stagger: Time(1, 10))
        #expect(AnimationSet(single: KeyframeTemplate(textAnimator: anim))?.entranceCoverage(clipTime: .zero) { nil } == 1)
    }

    @Test func tailOpacityIsWhatTheEnteringCaptionLeavesUncovered() throws {
        let fade = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)])],
                                    duration: Time(1, 5))
        var fadeOut = fade; fadeOut.anchor = .end
        let inSet = AnimationSet(single: fade), outSet = AnimationSet(single: fadeOut)
        #expect(CaptionHandover.tailOpacity(previous: inSet, entering: inSet, clipTime: .zero) { nil } == 1)
        #expect(abs(CaptionHandover.tailOpacity(previous: nil, entering: inSet, clipTime: Time(1, 20)) { nil } - 0.75) < 1e-9)
        #expect(CaptionHandover.tailOpacity(previous: inSet, entering: inSet, clipTime: Time(1, 5)) { nil } == 0)
        #expect(CaptionHandover.tailOpacity(previous: outSet, entering: inSet, clipTime: .zero) { nil } == 0)   // gone at its end
        #expect(CaptionHandover.tailOpacity(previous: inSet, entering: outSet, clipTime: .zero) { nil } == 0)
        #expect(CaptionHandover.tailOpacity(previous: inSet, entering: nil, clipTime: .zero) { nil } == 0)
    }

    @Test func entranceEndNeedsNoUnits() throws {
        let fade = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (Time(1, 5), 1, .linear)])],
                                    duration: Time(1, 5))
        let set = try #require(AnimationSet(single: fade))
        #expect(set.entranceEnd == Time(1, 5))
        var out = fade; out.anchor = .end
        #expect(AnimationSet(single: out)?.entranceEnd == .zero)
        var loop = fade; loop.loops = true
        #expect(AnimationSet(single: loop)?.entranceEnd == .zero)
        // A text animator: over once its first unit is in, however many units follow; from then on nobody asks for units.
        let anim = TextAnimator(effect: .fade, unit: .word, duration: Time(3, 10), stagger: Time(1, 10))
        let animSet = try #require(AnimationSet(single: KeyframeTemplate(textAnimator: anim)))
        #expect(animSet.entranceEnd == Time(3, 10))
        var asked = 0
        let units = TextUnits.segment(text: "one two three", lines: [NSRange(location: 0, length: 13)])
        #expect(animSet.entranceCoverage(clipTime: Time(3, 10)) { asked += 1; return units } == 1)
        #expect(animSet.entranceCoverage(clipTime: Time(2, 1)) { asked += 1; return units } == 1)
        #expect(asked == 0)
        #expect(animSet.entranceCoverage(clipTime: .zero) { asked += 1; return units } == 0)
        #expect(asked == 1)
        #expect(CaptionHandover.tailOpacity(previous: nil, entering: animSet, clipTime: Time(1, 1)) { asked += 1; return units } == 0)
        #expect(asked == 1)
    }

    /// A decoded track can hold overlapping captions: the first one containing the time shows (as the burn-in draws it).
    @Test func overlappingAndZeroLengthCaptions() throws {
        func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem { CaptionItem(lines: [text], range: r(a, b), styleRef: "s") }
        var track = CaptionTrack(items: [item("a", 0, 5), item("b", 2, 3)])
        func texts(_ n: Int64) -> [String] {
            track.slot(at: f(n), frameDuration: fd).map { [$0.tail?.text, $0.item.text].compactMap { $0 } } ?? []
        }
        #expect(texts(4) == ["a"])
        #expect(texts(2) == ["a"] && texts(5).isEmpty)
        // A blank caption lying over others does not make the track overlap: "a" still hands over to "c".
        track = CaptionTrack(items: [item("a", 0, 5), item(" ", 2, 7), item("c", 5, 9)])
        #expect(texts(5) == ["a", "c"] && texts(4) == ["a"])
        // A zero-length caption does not exist: "b" shows at its start and "a" is its tail.
        track = CaptionTrack(items: [item("a", 0, 1), item("b", 1, 2), item("z", 1, 1)])
        #expect(texts(1) == ["a", "b"])
        track = CaptionTrack(items: [item("a", 0, 1), item("z", 1, 1), item("b", 1, 2)])
        #expect(texts(1) == ["a", "b"] && texts(0) == ["a"] && texts(2).isEmpty)
    }

    @Test func slotsHandOverOnATrack() throws {
        var tl = Timeline(name: "c", format: SequenceFormat(width: 1080, height: 1920, frameDuration: fd), tracks: [])
        func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem { CaptionItem(lines: [text], range: r(a, b), styleRef: "s") }
        _ = try tl.replaceCaptions([item("a", 3, 15), item("b", 15, 27), item("c", 29, 40), item("d", 43, 50),
                                    item(" ", 50, 52), item("e", 52, 60)])
        func texts(_ n: Int64) -> [String] { tl.captionSlots(at: f(n)).flatMap { [$0.tail?.text, $0.item.text].compactMap { $0 } } }
        #expect(texts(2).isEmpty)
        #expect(texts(3) == ["a"])
        #expect(texts(15) == ["a", "b"] && texts(26) == ["a", "b"])
        let b = try #require(tl.captionSlots(at: f(27)).first)                   // the two-frame gap: "b" holds
        #expect(b.item.text == "b" && b.held && b.duration == f(14) && b.tailDuration == f(12))
        #expect(texts(29) == ["b", "c"])
        #expect(tl.captionSlots(at: f(29)).first?.tailDuration == f(14))
        #expect(texts(40).isEmpty && texts(42).isEmpty)                         // three frames: a real gap
        #expect(texts(43) == ["d"])
        // A blank caption does not exist: "d" hands over to "e" across it (two frames), and "e" has "d" as its tail.
        let d = try #require(tl.captionSlots(at: f(51)).first)
        #expect(d.item.text == "d" && d.held && d.duration == f(9))
        #expect(texts(52) == ["d", "e"])
        #expect(texts(60).isEmpty)
        // Every frame from 3 to 39 shows a caption; the plain lookup leaves the gap frames out.
        #expect((3..<40).allSatisfy { !tl.captionSlots(at: f($0)).isEmpty })
        #expect(tl.captions(at: f(27)).isEmpty)
        tl.captionTracks[0].isVisible = false
        #expect(tl.captionSlots(at: f(15)).isEmpty)
    }
}
