import Foundation
import Testing
@testable import SQAnalysis

@Suite(.serialized) struct AnalysisCacheLocationTests {
    @Test func configuredRootDecidesStabilizerAndSubjectMaskFolders() {
        let root = URL(fileURLWithPath: "/Volumes/Fast/C", isDirectory: true)
        AnalysisCacheLocation.configure(root: root)
        defer { AnalysisCacheLocation.configure(root: nil) }
        #expect(StabilizationCache().root.path == "/Volumes/Fast/C/Stabilizer")
        #expect(EdgeTAMLoader.compiledCache.path == "/Volumes/Fast/C/SubjectMask")
        #expect(AnalysisCacheLocation.directory("MagicMattes") { nil }?.path == "/Volumes/Fast/C/MagicMattes")
    }

    @Test func withoutRootTheHistoricFoldersStay() {
        AnalysisCacheLocation.configure(root: nil)
        #expect(StabilizationCache().root.path.hasSuffix("Library/Caches/Sequence Studio/Stabilizer"))
        #expect(EdgeTAMLoader.compiledCache.path.hasSuffix("Library/Caches/Sequence Studio/SubjectMask"))
        #expect(AnalysisCacheLocation.directory("MagicMattes") { URL(fileURLWithPath: "/legacy") }?.path == "/legacy")
    }

    @Test func explicitCachesDirectoryStillWins() {
        let c = StabilizationCache(cachesDirectory: URL(fileURLWithPath: "/t", isDirectory: true))
        #expect(c.root.path == "/t/Sequence Studio/Stabilizer")
    }
}
