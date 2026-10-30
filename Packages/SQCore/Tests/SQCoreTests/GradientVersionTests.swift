import Foundation
import Testing
@testable import SQCore

/// v51: the `gradient` effect kind is version-gated; files without one keep their lower version.
@Suite struct GradientVersionTests {
    private func project(effects: [ClipEffect] = []) throws -> Project {
        var tr = Track(kind: .video)
        try tr.overwrite(Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                              start: .zero, effects: effects))
        return Project(name: "P", timelines: [Timeline(name: "T", frameDuration: Time(1, 30), tracks: [tr])])
    }

    @Test func gradientFileIsWrittenAsV51() throws {
        let g = try #require(ClipEffect.make(kind: ClipEffect.gradientKind))
        let p = try project(effects: [g])
        #expect(ProjectFile.currentVersion >= 51 && ProjectFile.writtenVersion(for: p) == 51)
        let obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 51)
    }

    @Test func noGradientKeepsAnOlderVersionAndNoUnknownKind() throws {
        let blur = try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind))
        let p = try project(effects: [blur])
        #expect(ProjectFile.writtenVersion(for: p) < 51)
        let text = String(decoding: try ProjectFile.encode(p), as: UTF8.self)
        #expect(!text.contains("\"gradient\""))
    }

    @Test func v50StepIsIdentity() throws {
        let step = ProjectFile.migrations[50]
        #expect(step != nil)
        #expect(try step?(["a": 1])["a"] as? Int == 1)
        #expect(ProjectFile.identityMigrationsFrom <= 50)
    }

    @Test func fadesWithoutARangeStampV50() throws {
        var e = try #require(ClipEffect.make(kind: ClipEffect.gaussianBlurKind))
        e.colorFadeIn = Time(1, 1)
        let p = try project(effects: [e])
        #expect(p.containsRangeFades)
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.rangeFadeVersion)
    }
}
