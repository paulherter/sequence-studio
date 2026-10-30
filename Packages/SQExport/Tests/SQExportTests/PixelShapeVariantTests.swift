import Foundation
import SQCore
import Testing
@testable import SQExport

// "Export all formats" on a non-square sequence: every variant gets its own size and pixel aspect.
struct PixelShapeVariantTests {
    private func timeline() -> Timeline {
        var f = SequenceFormat(width: 1440, height: 1080, frameDuration: Time(1, 30), audioSampleRate: 48000)
        f.pixelAspect = PixelAspect(4, 3)!
        var t = Timeline(name: "S", format: f)
        t.variants = [FormatVariant(name: "9:16", width: 1080, height: 1920)]
        return t
    }

    private func jobs(_ s: ExportSettings) -> [ExportJob] {
        ExportJob.variantJobs(name: "P", settings: s, outputDirectory: URL(fileURLWithPath: "/tmp"), timeline: timeline()) { _ in throw ExportError.emptySource }
    }

    @Test func variantKeepsTheSequenceShapeAndScale() {
        let s = ExportPreset.matchSource.settings(matching: timeline().format)
        let j = jobs(s)
        #expect(j[1].settings.video.pixelAspect == PixelAspect(4, 3)!)
        #expect(j[1].settings.video.width == 1080 && j[1].settings.video.height == 1920)
        var half = s; half.video.width = 720; half.video.height = 540
        #expect(jobs(half)[1].settings.video.width == 540 && jobs(half)[1].settings.video.pixelAspect == PixelAspect(4, 3)!)
    }

    @Test func squareExportOfShapedSequenceGivesSquareVariantAtDisplayAspect() {
        var s = ExportSettings(); s.video.width = 1920; s.video.height = 1080     // square export at the sequence's display width
        let j = jobs(s)
        #expect(j[0].settings.video.pixelAspect == .square && j[1].settings.video.pixelAspect == .square)
        #expect(j[1].settings.video.width == 1440 && j[1].settings.video.height == 1920)
    }
}
