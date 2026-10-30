import Foundation
import Testing
@testable import SQCore

// F7.11: Mosaic by block size. The stored effect stays Columns / Rows (no new key); a block size in px is turned into the
// grid of square blocks for the clip's frame.

@Suite struct MosaicBlockSizeTests {
    @Test func blockSizeGivesSquareBlocksOnAnyAspect() {
        #expect(ClipEffect.mosaicGrid(blockSize: 40, width: 1920, height: 1080) == MosaicGrid(columns: 48, rows: 27))
        #expect(ClipEffect.mosaicGrid(blockSize: 40, width: 1080, height: 1920) == MosaicGrid(columns: 27, rows: 48))
        // Not a divisor: the nearest whole grid, blocks within half a block of the wish.
        #expect(ClipEffect.mosaicGrid(blockSize: 37, width: 1920, height: 1080) == MosaicGrid(columns: 52, rows: 29))
    }

    @Test func blockSizeIsClampedToTheParameterRange() {
        #expect(ClipEffect.mosaicGrid(blockSize: 0, width: 1920, height: 1080) == MosaicGrid(columns: 1920, rows: 1080))
        #expect(ClipEffect.mosaicGrid(blockSize: -3, width: 64, height: 32) == MosaicGrid(columns: 64, rows: 32))
        #expect(ClipEffect.mosaicGrid(blockSize: 100_000, width: 1920, height: 1080) == MosaicGrid(columns: 1, rows: 1))
        #expect(ClipEffect.mosaicGrid(blockSize: 1, width: 8_000, height: 6_000) == MosaicGrid(columns: 4_000, rows: 4_000))
        #expect(ClipEffect.mosaicGrid(blockSize: 10, width: 0, height: 0) == MosaicGrid(columns: 1, rows: 1))
    }

    @Test func mosaicEffectWithABlockSizeEvaluatesToThatGrid() {
        let e = ClipEffect.mosaic(blockSize: 60, width: 1920, height: 1080)
        #expect(e.kind == ClipEffect.mosaicKind)
        #expect(e.imageFilter(atLocal: .zero) == .mosaic(columns: 32, rows: 18, sharp: false))
        // Every parameter of the catalog is there, so Effect Controls shows the effect like one dropped from the panel.
        #expect(Set(e.parameters.keys) == Set(ClipEffect.defaultParameters(for: ClipEffect.mosaicKind).keys))
    }

    @Test func anonymizeBlockSizeFollowsTheSubjectNotTheFrame() {
        // About eight blocks across the covered width, never finer than 1/60 of the frame's short side (a face that is
        // small in the frame must not stay readable through fine blocks).
        #expect(ClipEffect.anonymizeBlockSize(subjectWidth: 400, frameWidth: 1920, frameHeight: 1080) == 50)
        #expect(ClipEffect.anonymizeBlockSize(subjectWidth: 40, frameWidth: 1920, frameHeight: 1080) == 18)
        #expect(ClipEffect.anonymizeBlockSize(subjectWidth: 0, frameWidth: 3840, frameHeight: 2160) == 36)
    }
}
