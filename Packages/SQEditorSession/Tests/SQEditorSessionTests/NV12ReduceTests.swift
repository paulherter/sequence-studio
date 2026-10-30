import Testing
import SQCore
@testable import SQEditorSession

/// The playback quality's NV12 box reduction (Windows engine, `WinProgramEngine.quality`).
@Suite struct NV12ReduceTests {
    /// An 8 x 8 picture: luma = x * 10 + y, Cb = 100 + x, Cr = 200 - y per chroma pair.
    private func picture() -> [UInt8] {
        var b: [UInt8] = []
        for y in 0..<8 { for x in 0..<8 { b.append(UInt8(x * 10 + y)) } }
        for y in 0..<4 { for x in 0..<4 { b.append(UInt8(100 + x)); b.append(UInt8(200 - y)) } }
        return b
    }

    @Test func halfAveragesTwoByTwo() throws {
        let r = try #require(NV12Reduce.reduce(picture(), width: 8, height: 8, by: 2))
        #expect(r.width == 4 && r.height == 4 && r.bytes.count == 24)
        // Luma (0,0): samples 0, 10, 1, 11 -> 5.5 rounds to 6; (3,3): 66, 76, 67, 77 -> 71.5 -> 72.
        #expect(r.bytes[0] == 6 && r.bytes[15] == 72)
        // Chroma pair (0,0): Cb 100, 101 -> 100.5 -> 101; Cr 200, 199 -> 199.5 -> 200. Pair (1,1): Cb 102.5, Cr 197.5.
        #expect(r.bytes[16] == 101 && r.bytes[17] == 200)
        #expect(r.bytes[22] == 103 && r.bytes[23] == 198)
    }

    @Test func quarterAndRefusals() throws {
        let r = try #require(NV12Reduce.reduce(picture(), width: 8, height: 8, by: 4))
        #expect(r.width == 2 && r.height == 2 && r.bytes.count == 6)
        #expect(r.bytes[0] == 17)          // mean of x*10+y over 0..3: 15 + 1.5 = 16.5 -> 17
        #expect(NV12Reduce.reduce(picture(), width: 8, height: 8, by: 1) == nil)
        #expect(NV12Reduce.reduce(picture(), width: 6, height: 8, by: 2) == nil)    // 6 / 2 = 3 luma: odd chroma
        #expect(NV12Reduce.reduce(Array(picture().prefix(50)), width: 8, height: 8, by: 2) == nil)
        #expect(NV12Reduce.divisor(.full) == 1 && NV12Reduce.divisor(.half) == 2 && NV12Reduce.divisor(.quarter) == 4)
    }
}
