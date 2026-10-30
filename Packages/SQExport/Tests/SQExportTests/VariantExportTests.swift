import Testing
import Foundation
import SQCore
@testable import SQExport

/// W5.1: "export all formats" makes one job per variant, named after it, sized like the variant.
@Suite struct VariantExportTests {
    func timeline() throws -> Timeline {
        var t = Timeline(name: "Promo", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25), audioSampleRate: 48000))
        try t.addVariant(name: "9:16", width: 1080, height: 1920)
        try t.addVariant(name: "1:1", width: 1080, height: 1080)
        return t
    }

    func settings(_ w: Int, _ h: Int) -> ExportSettings {
        var s = ExportSettings(); s.video.width = w; s.video.height = h; return s
    }

    @Test func oneJobPerVariantPlusTheBaseNamedAfterTheVariant() throws {
        let t = try timeline()
        let jobs = ExportJob.variantJobs(name: "Promo", settings: settings(1920, 1080), outputDirectory: URL(fileURLWithPath: "/tmp"),
                                         timeline: t) { _ in throw ExportError.emptySource }
        #expect(jobs.map(\.name) == ["Promo", "Promo 9:16", "Promo 1:1"])
        #expect(ExportQueue.sanitize(jobs[1].name) == "Promo 9-16")          // the file name carries the variant name
        #expect(jobs.map(\.settings.variant) == [nil] + t.variants.map(\.id))
        #expect(jobs[1].settings.video.width == 1080 && jobs[1].settings.video.height == 1920)
        #expect(jobs[2].settings.video.width == 1080 && jobs[2].settings.video.height == 1080)
    }

    @Test func exportSizeScalesWithTheVariantAndStaysEven() throws {
        let t = try timeline()
        // Exporting the 1920x1080 sequence at 1280x720: the 9:16 variant goes out at 720x1280, 1:1 at 720x720.
        let jobs = ExportJob.variantJobs(name: "P", settings: settings(1280, 720), outputDirectory: URL(fileURLWithPath: "/tmp"),
                                         timeline: t) { _ in throw ExportError.emptySource }
        #expect(jobs[1].settings.video.width == 720 && jobs[1].settings.video.height == 1280)
        #expect(jobs[2].settings.video.width == 720 && jobs[2].settings.video.height == 720)
        let odd = ExportJob.variantJobs(name: "P", settings: settings(1000, 562), outputDirectory: URL(fileURLWithPath: "/tmp"),
                                        timeline: t) { _ in throw ExportError.emptySource }
        for j in odd { #expect(!j.settings.validate().contains(.oddDimensions)) }
    }

    @Test func noVariantsIsJustTheBaseJob() throws {
        let t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25), audioSampleRate: 48000))
        let jobs = ExportJob.variantJobs(name: "S", settings: settings(1920, 1080), outputDirectory: URL(fileURLWithPath: "/tmp"),
                                         timeline: t) { _ in throw ExportError.emptySource }
        #expect(jobs.count == 1 && jobs[0].settings.variant == nil && jobs[0].name == "S")
    }

    @Test func eachJobBuildsItsSourcesWithItsOwnSettings() async throws {
        let t = try timeline()
        let seen = Seen()
        let jobs = ExportJob.variantJobs(name: "S", settings: settings(1920, 1080), outputDirectory: URL(fileURLWithPath: "/tmp"),
                                         timeline: t) { s in await seen.add(s.variant); throw ExportError.emptySource }
        for j in jobs { _ = try? await j.makeSources() }
        #expect(await seen.items == [nil] + t.variants.map(\.id))
    }

    @Test func settingsWithoutVariantDecodeFromOlderJSON() throws {
        let s = ExportSettings()
        let data = try JSONEncoder().encode(s)
        #expect(!String(decoding: data, as: UTF8.self).contains("variant"))
        #expect(try JSONDecoder().decode(ExportSettings.self, from: data).variant == nil)
    }
}

private actor Seen {
    var items: [UUID?] = []
    func add(_ v: UUID?) { items.append(v) }
}
