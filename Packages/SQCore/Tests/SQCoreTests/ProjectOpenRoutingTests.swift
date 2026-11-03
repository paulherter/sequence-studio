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

    @Test func resolvesChosenFolderToProject() {
        let none: (URL) -> Bool = { _ in false }
        let pkg = URL(fileURLWithPath: "/v/MacBook OLED kaufen.sqproj")
        #expect(ProjectOpenRouting.projectFolder(chosen: pkg, hasProjectJSON: none)?.path == pkg.path)
        #expect(ProjectOpenRouting.projectFolder(chosen: pkg.appendingPathComponent("media"), hasProjectJSON: none)?.path == pkg.path)
        let plain = URL(fileURLWithPath: "/v/Plain")
        #expect(ProjectOpenRouting.projectFolder(chosen: plain, hasProjectJSON: none) == nil)
        #expect(ProjectOpenRouting.projectFolder(chosen: plain, hasProjectJSON: { $0.path == plain.path })?.path == plain.path)
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
