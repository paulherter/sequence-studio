import SQCore
import Testing
@testable import SQMedia

/// Closed GOP 6 with B-frames: decode order I P B B P B ... presentation I B B P B B style.
/// Builds entries from a presentation-order list of (decodeOrdinal, isSync).
private func makeIndex(pts: [Int64], dec: [Int], sync: Set<Int>, scale: Int64 = 30, offset: Int64 = 0) -> SampleIndex {
    let es = zip(pts, dec).map { p, d in
        SampleIndex.Entry(pts: Time(p + offset, scale), dts: Time(Int64(d) + offset - 2, scale), duration: Time(1, scale),
                          isSync: sync.contains(d), decodeOrdinal: d)
    }
    return SampleIndex(entries: es.shuffled())
}

// Presentation 0..11, two closed GOPs of 6. Decode order per GOP: I0 P3 B1 B2 P... (I at 0, P at 3, B 1,2, P 5? keep simple)
// GOP A presentation 0...5 decode ordinals: 0:0 1:2 2:3 3:1 4:5 5:4 ; GOP B presentation 6...11 ordinals +6.
private let presDec: [Int] = [0, 2, 3, 1, 5, 4, 6, 8, 9, 7, 11, 10]

@Test func normalisesFirstPresentedFrameToZeroAndSorts() {
    let idx = makeIndex(pts: Array(0..<12), dec: presDec, sync: [0, 6], offset: 100)
    #expect(idx.entries.first?.pts == .zero)
    #expect(zip(idx.entries, idx.entries.dropFirst()).allSatisfy { $0.pts < $1.pts })
    #expect(idx.entries.map(\.decodeOrdinal) == presDec)
    #expect(idx.duration == Time(12, 30))
}

@Test func frameLookupOutsideRangeIsNil() {
    let idx = makeIndex(pts: Array(0..<12), dec: presDec, sync: [0, 6])
    #expect(idx.frame(at: Time(-1, 30)) == nil)
    #expect(idx.frame(at: Time(12, 30)) == nil)
    #expect(idx.frame(at: Time(5, 1)) == nil)
    #expect(idx.frame(at: .zero) == 0)
    #expect(idx.frame(at: Time(11, 30)) == 11)
    #expect(idx.frame(at: Time(3, 30)) == 3)
    #expect(idx.frame(at: Time(3, 30) + Time(1, 60)) == 3)
}

@Test func frameLookupIsVFRSafe() {
    // pts in 1/60: 0, 2, 3, 7, 8, 12 with durations to next.
    let p: [Int64] = [0, 2, 3, 7, 8, 12]
    let es = p.enumerated().map { i, v in
        SampleIndex.Entry(pts: Time(v, 60), dts: Time(v, 60), duration: Time((i + 1 < p.count ? p[i + 1] : 14) - v, 60),
                          isSync: i == 0, decodeOrdinal: i)
    }
    let idx = SampleIndex(entries: es)
    #expect(idx.frame(at: Time(1, 60)) == 0)
    #expect(idx.frame(at: Time(2, 60)) == 1)
    #expect(idx.frame(at: Time(6, 60)) == 2)
    #expect(idx.frame(at: Time(7, 60)) == 3)
    #expect(idx.frame(at: Time(13, 60)) == 5)
    #expect(idx.frame(at: Time(14, 60)) == nil)
}

@Test func gopRangesWithBFrameReorder() {
    let idx = makeIndex(pts: Array(0..<12), dec: presDec, sync: [0, 6])
    for i in 0..<6 { #expect(idx.gop(containing: i) == 0...5) }
    for i in 6..<12 { #expect(idx.gop(containing: i) == 6...11) }
    #expect(idx.syncDecodeOrdinal(for: 4) == 0)
    #expect(idx.syncDecodeOrdinal(for: 9) == 6)
}

/// Open GOP (x265 CRA): the CRA at presentation 8 is decoded before the leading pictures 6 and 7, which reference GOP A.
@Test func freshDecodeStartStepsBackForLeadingPicturesOfAnOpenGOP() {
    let idx = makeIndex(pts: Array(0..<12), dec: [0, 2, 3, 1, 5, 4, 7, 8, 6, 10, 11, 9], sync: [0, 6])
    #expect(idx.syncDecodeOrdinal(for: 7) == 6)        // the CRA's GOP in decode order
    #expect(idx.freshDecodeStart(for: 6) == 0)         // leading pictures: start at GOP A
    #expect(idx.freshDecodeStart(for: 7) == 0)
    #expect(idx.freshDecodeStart(for: 8) == 8)         // the CRA and the frames after it: unchanged (their GOP's sync)
    #expect(idx.freshDecodeStart(for: 11) == 11)
    #expect(idx.syncDecodeOrdinal(for: 11) == 6)
    #expect(idx.freshDecodeStart(for: 5) == 5)
    #expect(idx.freshDecodeStart(for: 0) == 0)
    // Closed GOPs never step back.
    let closed = makeIndex(pts: Array(0..<12), dec: presDec, sync: [0, 6])
    #expect((0..<12).allSatisfy { closed.freshDecodeStart(for: $0) == $0 })
}

@Test func previousSync() {
    let idx = makeIndex(pts: Array(0..<12), dec: presDec, sync: [0, 6])
    #expect(idx.previousSync(before: 0) == 0)
    #expect(idx.previousSync(before: 5) == 0)
    #expect(idx.previousSync(before: 6) == 0)
    #expect(idx.previousSync(before: 7) == 6)
    #expect(idx.previousSync(before: 11) == 6)
}

@Test func singleGopAndEmpty() {
    let one = makeIndex(pts: [0, 1, 2], dec: [0, 2, 1], sync: [0])
    #expect(one.gop(containing: 2) == 0...2)
    #expect(SampleIndex(entries: []).frame(at: .zero) == nil)
}
