import Foundation
import Testing
@testable import SQCore

@Suite struct ProjectOpenRoutingTests {
    @Test func routesByExtension() {
        #expect(ProjectOpenRouting.route(for: URL(fileURLWithPath: "/a/b.sqproj")) == .sequenceStudioProject)
        #expect(ProjectOpenRouting.route(for: URL(fileURLWithPath: "/a/b.ssproj")) == .sequenceStudioProject)
        #expect(ProjectOpenRouting.route(for: URL(fileURLWithPath: "/a/B.PRPROJ")) == .premiereImport)
        #expect(ProjectOpenRouting.route(for: URL(fileURLWithPath: "/a/b.mov")) == .unsupported)
    }

    @Test func mapsProjectFileErrors() throws {
        let missing = try #require(ProjectOpenRouting.message(for: ProjectFileError.missing, fileName: "x"))
        #expect(missing.detail.contains("not a Sequence Studio project"))
        let corrupt = try #require(ProjectOpenRouting.message(for: ProjectFileError.corrupt, fileName: "x"))
        #expect(corrupt.detail.contains("damaged"))
        let newer = try #require(ProjectOpenRouting.message(for: ProjectFileError.newerVersion(found: 9, supported: 1), fileName: "x"))
        #expect(newer.detail.contains("newer version"))
        #expect(ProjectOpenRouting.message(for: CocoaError(.fileNoSuchFile), fileName: "x") == nil)
    }
}
