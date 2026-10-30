import CoreVideo
import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI

@MainActor @Suite struct ExportDeliveryChipsTests {
    private struct TestFrames: FrameSource {
        let width = 64, height = 64, frameCount = 1, frameDuration = Time(1, 30)
        func frame(at index: Int) async throws -> CVPixelBuffer { throw CancellationError() }
    }

    @Test func sourceTraitsAndEncoderReachTheDialog() {
        let item = ExportDialogModel.SequenceItem(name: "Seq", duration: Time(seconds: 4),
                                                  format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                                                  sourceTraits: .init(hasVariableFrameRate: true, hasInterlaced: true))
        let m = ExportDialogModel(sequences: [item], initialPreset: nil) { _, _ in ExportSources(video: TestFrames(), audio: nil) }
        let ids = m.deliveryIssues.map(\.id)
        #expect(ids.contains("vfr") && ids.contains("interlaced"))
        #expect(m.deliveryNotes.contains { $0.contains("ncoder") })
    }
}
