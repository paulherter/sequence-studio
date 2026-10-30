import Foundation
import SQCore
import Testing
@testable import SQAnalysis

/// Export reads the store only under the accurate key and only for a clip whose range is fully stored.
@Suite struct ExportSubjectMattesTests {
    private let media = UUID()
    private let file = URL(fileURLWithPath: "/tmp/sq-export-matte-test.mov")

    private func fill(_ store: MagicMatteStore, quality: PersonSegmenter.Quality, frames: Int, skipping: Int? = nil) {
        let key = SubjectMattePrecompute.cacheKey(media: media, path: file.path, quality: quality)
        for i in 0..<frames where i != skipping {
            store.put(SubjectMatte(width: 2, height: 2, values: [1, 1, 1, 1]), key: key, pts: Double(i) / 24)
        }
    }

    @Test func qualitiesNeverShareAKey() {
        let a = SubjectMattePrecompute.cacheKey(media: media, path: file.path)
        let b = SubjectMattePrecompute.cacheKey(media: media, path: file.path, quality: .accurate)
        #expect(a != b)
        #expect(a == SubjectMattePrecompute.cacheKey(media: media, path: file.path, quality: .balanced))
    }

    /// Export's key names the field order its decoder deinterlaces with: mattes stored for the woven frames (Deinterlace
    /// off, or before the switch) do not count for the deinterlaced ones. Progressive media keeps its key.
    @Test func theKeyNamesTheFieldOrder() {
        let store = MagicMatteStore(directory: nil)
        fill(store, quality: .accurate, frames: 24)
        let plain = ExportSubjectMattes(store: store) { [file] _ in file }
        let fields = ExportSubjectMattes(store: store, deinterlace: { _ in .topFirst }) { [file] _ in file }
        #expect(plain.key(media: media) == SubjectMattePrecompute.cacheKey(media: media, path: file.path, quality: .accurate))
        #expect(fields.key(media: media)
                == SubjectMattePrecompute.cacheKey(media: media, path: file.path, quality: .accurate, deinterlace: .topFirst))
        #expect(plain.covers(media: media, from: 0, to: 23.0 / 24))
        #expect(!fields.covers(media: media, from: 0, to: 23.0 / 24))
    }

    @Test func balancedMattesDoNotCountForExport() {
        let store = MagicMatteStore(directory: nil)
        fill(store, quality: .balanced, frames: 24)
        let ex = ExportSubjectMattes(store: store) { [file] _ in file }
        #expect(!ex.covers(media: media, from: 0, to: 23.0 / 24))
    }

    @Test func accurateMattesCoverAFullRangeOnly() {
        let store = MagicMatteStore(directory: nil)
        fill(store, quality: .accurate, frames: 24)
        let ex = ExportSubjectMattes(store: store) { [file] _ in file }
        #expect(ex.covers(media: media, from: 0, to: 23.0 / 24))
        #expect(!ex.covers(media: media, from: 0, to: 3))
        #expect(ex.matte(media: media, pts: 5.0 / 24) != nil)
        let holed = MagicMatteStore(directory: nil)
        fill(holed, quality: .accurate, frames: 24, skipping: 10)
        let exHoled = ExportSubjectMattes(store: holed) { [file] _ in file }
        let exNoFile = ExportSubjectMattes(store: store) { _ in nil }
        #expect(!exHoled.covers(media: media, from: 0, to: 23.0 / 24))
        #expect(!exNoFile.covers(media: media, from: 0, to: 1))
    }
}

@Suite struct MagicHealthSamplesTests {
    @Test func samplesAreTheCoverageOfEachStoredFrame() {
        let store = MagicMatteStore(directory: nil)
        func matte(_ covered: Int) -> SubjectMatte {
            SubjectMatte(width: 10, height: 10, values: (0..<100).map { $0 < covered ? 1 : 0 })
        }
        store.put(matte(50), key: "k", pts: 0.5)
        store.put(matte(10), key: "k", pts: 0.25)
        let s = store.healthSamples(key: "k")
        #expect(s.map(\.pts) == [0.25, 0.5])
        #expect(abs(s[0].area - 0.1) < 0.01 && abs(s[1].area - 0.5) < 0.01)
        #expect(store.healthSamples(key: "none").isEmpty)
    }
}
