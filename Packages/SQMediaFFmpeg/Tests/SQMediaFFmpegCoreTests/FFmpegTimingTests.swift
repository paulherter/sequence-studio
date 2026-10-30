import SQCore
import SQMedia
import SQMediaFFmpegCore
import Testing

@Suite struct FFmpegTimingTests {
    let tb = FFmpegTimeBase(num: 1, den: 15_360)

    @Test func ticksRoundTripExactly() {
        for ticks: Int64 in [0, 1, 512, 15_360, 1_234_567, -512] {
            #expect(tb.ticks(tb.time(ticks: ticks)) == ticks)
        }
        #expect(tb.time(ticks: 512) == Time(1, 30))
        #expect(FFmpegTimeBase(num: 1001, den: 30_000).time(ticks: 3) == Time(3003, 30_000))
    }

    @Test func offGridTimeRoundsToNearestTick() {
        #expect(tb.ticks(Time(1, 61_440)) == 0)          // a quarter tick
        #expect(tb.ticks(Time(1, 30_720)) == 1)          // half a tick rounds up
        #expect(tb.ticks(Time(-1, 30_720)) == -1)        // and away from zero below it
    }

    /// I P B B, as a B-frame encoder writes it: decode order differs from presentation order, pts starts at 1024.
    private func reorderedPackets() -> [FFmpegPacketTiming] {
        let d: Int64 = 512
        return [FFmpegPacketTiming(pts: 1024, dts: 0, duration: d, isKey: true),
                FFmpegPacketTiming(pts: 2560, dts: 512, duration: d, isKey: false),
                FFmpegPacketTiming(pts: 1536, dts: 1024, duration: d, isKey: false),
                FFmpegPacketTiming(pts: 2048, dts: 1536, duration: d, isKey: false),
                FFmpegPacketTiming(pts: 3072, dts: 2048, duration: d, isKey: true),
                FFmpegPacketTiming(pts: 3584, dts: 2560, duration: d, isKey: false)]
    }

    @Test func frameTableMapsDecodedPtsToPresentationOrder() {
        let table = FFmpegFrameTable(packets: reorderedPackets(), timeBase: tb)
        #expect(table.index.count == 6)
        #expect(table.index.entries.map(\.decodeOrdinal) == [0, 2, 3, 1, 4, 5])
        #expect(table.index.entries[0].pts == .zero)
        #expect(table.index.entries[3].pts == Time(3, 30))
        #expect(table.presentationIndex(ofTicks: 2560) == 3)
        #expect(table.presentationIndex(ofTicks: 1024) == 0)
        #expect(table.presentationIndex(ofTicks: 999) == nil)
        #expect(table.ticks(table.index.entries[3].pts) == 2560)
    }

    @Test func seekStartsAtTheSyncSampleAndFlushes() {
        let table = FFmpegFrameTable(packets: reorderedPackets(), timeBase: tb)
        let s = FFmpegDecodePlan.start(for: 2...3, in: table.index, cursor: nil)
        #expect(s.ordinal == 0 && s.flush)
        // Behind the frames already sent (presentation 1 is decode ordinal 2): a seek.
        let back = FFmpegDecodePlan.start(for: 1...1, in: table.index, cursor: FFmpegDecodeCursor(nextOrdinal: 4, lastPresented: 3))
        #expect(back.ordinal == 0 && back.flush)
        // Far ahead (the GOP at ordinal 4 while the decoder is still at ordinal 1): a seek, not decoding the gap.
        let far = FFmpegDecodePlan.start(for: 5...5, in: table.index, cursor: FFmpegDecodeCursor(nextOrdinal: 1, lastPresented: 0))
        #expect(far.ordinal == 4 && far.flush)
    }

    /// x265 open GOP: the CRA (presentation 8) is sent before its leading pictures 6 and 7. A seek to one of them starts
    /// at the previous GOP's sync sample, since FFmpeg drops the RASL pictures of a CRA it starts at.
    @Test func seekToALeadingPictureStartsOneGOPEarlier() {
        let order: [Int64] = [0, 3, 1, 2, 5, 4, 8, 6, 7, 11, 9, 10]   // presentation frame of each decode ordinal
        let packets = order.enumerated().map { o, f in
            FFmpegPacketTiming(pts: 1024 + f * 512, dts: Int64(o) * 512, duration: 512, isKey: o == 0 || o == 6)
        }
        let index = FFmpegFrameTable(packets: packets, timeBase: tb).index
        for f in [6, 7] {
            let s = FFmpegDecodePlan.start(for: f...f, in: index, cursor: nil)
            #expect(s.ordinal == 0 && s.flush)
        }
        #expect(FFmpegDecodePlan.start(for: 8...8, in: index, cursor: nil).ordinal == 6)
        #expect(FFmpegDecodePlan.start(for: 9...10, in: index, cursor: nil).ordinal == 6)
        #expect(FFmpegDecodePlan.start(for: 3...7, in: index, cursor: nil).ordinal == 0)
        // GOP A sent (ordinals 0-5, last frame returned 5) and frame 6 skipped: 7 continues at the CRA instead of
        // decoding GOP A again.
        let skip = FFmpegDecodePlan.start(for: 7...7, in: index, cursor: FFmpegDecodeCursor(nextOrdinal: 6, lastPresented: 5))
        #expect(skip.ordinal == 6 && !skip.flush)
    }

    /// A jump ahead whose frames are all still to be sent (or carried over) continues, as the Mac decoder's plan does.
    @Test func shortJumpAheadContinuesWithoutFlush() {
        let table = FFmpegFrameTable(packets: reorderedPackets(), timeBase: tb)
        let s = FFmpegDecodePlan.start(for: 5...5, in: table.index, cursor: FFmpegDecodeCursor(nextOrdinal: 4, lastPresented: 1))
        #expect(s.ordinal == 4 && !s.flush)
        // Presentation 2 (ordinal 3) was already sent: only a carried picture lets the call continue.
        let cursor = FFmpegDecodeCursor(nextOrdinal: 4, lastPresented: 0)
        #expect(FFmpegDecodePlan.start(for: 2...5, in: table.index, cursor: cursor).flush)
        #expect(!FFmpegDecodePlan.start(for: 2...5, in: table.index, cursor: cursor, carried: [1, 2, 3]).flush)
    }

    @Test func forwardPlaybackContinuesWithoutFlush() {
        let table = FFmpegFrameTable(packets: reorderedPackets(), timeBase: tb)
        let s = FFmpegDecodePlan.start(for: 4...5, in: table.index, cursor: FFmpegDecodeCursor(nextOrdinal: 4, lastPresented: 3))
        #expect(s.ordinal == 4 && !s.flush)
    }

    @Test func wantedSkipsHiddenFrames() {
        var packets = reorderedPackets()
        packets[2].duration = 0
        let table = FFmpegFrameTable(packets: packets, timeBase: tb)
        let hidden = table.index.entries.firstIndex { $0.duration == .zero }!
        #expect(!FFmpegDecodePlan.wanted(0...5, in: table.index).contains(hidden))
        #expect(FFmpegDecodePlan.wanted(0...5, in: table.index).count == 5)
    }
}
