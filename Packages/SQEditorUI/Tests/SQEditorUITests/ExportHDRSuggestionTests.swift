import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI

@MainActor @Suite struct ExportHDRSuggestionTests {
    private func model(hdr: HDRDelivery.Transfer?, target: DeliveryTarget? = nil) -> ExportDialogModel {
        let f = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30))
        let item = ExportDialogModel.SequenceItem(name: "S", duration: Time(seconds: 10), format: f, deliveryTarget: target, hdrTarget: hdr)
        return ExportDialogModel(sequences: [item], initialPreset: nil) { _, _ in throw CancellationError() }
    }

    @Test func hdrClipSuggestsHEVCWithMatchingTransfer() {
        let pq = model(hdr: .pq)
        #expect(pq.settings.video.codec == .hevc)
        #expect(pq.settings.hdrDelivery?.transfer == .pq)
        #expect(model(hdr: .hlg).settings.hdrDelivery?.transfer == .hlg)
    }

    @Test func noHDRClipLeavesDeliveryOff() {
        #expect(model(hdr: nil).settings.hdrDelivery == nil)
    }

    @Test func userCanSwitchTheSuggestionOff() {
        let m = model(hdr: .pq)
        m.settings.hdrDelivery = nil
        #expect(m.settings.hdrDelivery == nil)
    }

    @Test func h264TargetKeepsItsCodecAndNoHDR() {
        let m = model(hdr: .pq, target: DeliveryTarget(platform: .tiktok))
        #expect(m.settings.video.codec != .hevc)
        #expect(m.settings.hdrDelivery == nil)
    }

    @Test func mostDemandingTransferWins() {
        #expect(HDRDelivery.Transfer.suggested(for: [.rec709, .rec2020HLG, .rec2020PQ]) == .pq)
        #expect(HDRDelivery.Transfer.suggested(for: [.rec709, .rec2020HLG]) == .hlg)
        #expect(HDRDelivery.Transfer.suggested(for: [.rec709, .rec2020]) == nil)
    }
}
