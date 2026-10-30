import Testing
@testable import SQCore

@Suite struct LUTSpaceHintTests {
    @Test func namesMapToSpaces() {
        #expect(LUTSpaceHint.expectedSpace(forFileName: "SLog3_to_Rec709.cube") == .sLog3SGamut3Cine)
        #expect(LUTSpaceHint.expectedSpace(forFileName: "Canon_CLog2_v2.cube") == .canonLog2CinemaGamut)
        #expect(LUTSpaceHint.expectedSpace(forFileName: "Warm Film.cube") == nil)
    }
    @Test func mismatchOnlyWhenDifferent() {
        #expect(LUTSpaceHint.mismatch(lutFileName: "VLog_look.cube", source: .rec709) != nil)
        #expect(LUTSpaceHint.mismatch(lutFileName: "VLog_look.cube", source: .vLogVGamut) == nil)
        #expect(LUTSpaceHint.mismatch(lutFileName: "CLog3.cube", source: .canonLog3BT709) == nil)
        #expect(LUTSpaceHint.mismatch(lutFileName: "Warm.cube", source: .rec709) == nil)
    }
}
