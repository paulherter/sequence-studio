import Foundation
import Testing
import SQExport
@testable import SQEditorUI

@MainActor @Suite struct ExportProgressPipHeightTests {
    @Test func doneCardIsTallerForFullSizeCheer() {
        let url = URL(fileURLWithPath: "/tmp/out.mp4")
        var m = ExportProgressModel(jobID: UUID(), name: "out", outputURL: url)
        m.update(state: .running, progress: 0.4, outputURL: url, now: 1)
        let v = ExportProgressView(model: m)
        #expect(v.preferredHeight == ExportProgressView.size.height)
        var changed: [CGFloat] = []
        v.onPreferredHeightChange = { changed.append($0) }
        m.update(state: .done(url), progress: 1, outputURL: url, now: 5)
        v.apply(m)
        #expect(v.preferredHeight > ExportProgressView.size.height)
        #expect(changed == [v.preferredHeight])
    }
}
