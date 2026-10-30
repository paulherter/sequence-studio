import Foundation
import Synchronization
import Testing
@testable import SQPremiereImport

/// Differential check for `PRMapper` speed-ups: canonical digests of every MapperTests map, recorded with the mapper as it
/// was before (2026-10-04). A digest mismatch means the output changed. Re-record only for an intended output change:
/// `SQ_MAP_GOLDEN_RECORD=/tmp/golden.txt scripts/test.sh SQPremiereImport`, then paste the lines into `digests`.
enum MapperGolden {
    static let counters = Mutex<[String: Int]>([:])

    static func nextKey(_ function: String) -> String {
        let n = counters.withLock { c -> Int in let n = c[function, default: 0]; c[function] = n + 1; return n }
        return "\(function)#\(n)"
    }

    static func check(_ r: PRImportResult, function: String) {
        let key = nextKey(function)
        let d = r.canonicalDigest()
        if let path = ProcessInfo.processInfo.environment["SQ_MAP_GOLDEN_RECORD"] {
            let line = "        \"\(key)\": \"\(d)\",\n"
            recordLock.withLock { _ in
                if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
            }
            return
        }
        #if !canImport(CoreText)
        return   // digests include text positions measured by Core Text; the portable text backend measures differently (WINDOWS-PLAN seam 2)
        #else
        guard let want = digests[function] else { return }
        #expect(want.contains(d), "PRMapper output changed for \(key)")
        #endif
    }
    static let recordLock = Mutex<Void>(())

    /// Function -> every digest its maps produced (a helper such as blendClip is called by tests running in parallel).
    static let digests: [String: Set<String>] = [
        "adjustmentLayerBecomesAdjustmentClip()": ["1cd33de701428de8"],   // 2026-10-06: Lumetri note text; text-only adjustment graphic reports "Adjustment layer area"
        "audioGainIsImported()": ["e23b4b89b9cc1b70"],   // 2026-10-05: Audio Gain -> Clip.audioGainDB
        "audioTransitionsKeepAudioKinds()": ["e6737578a4aa1066"],
        "audioVolumeAndLinking()": ["eb6c618e51bd6789"],
        "bezierKeysGetEaseHandles()": ["4ddc09e29d78ae5e"],
        // 2026-10-05: full blend set (every menu index maps; unknown index reported differently).
        "blendClip(code:index:)": ["228182622ab96c2f", "41b0c42c4c36875", "4c6458a8b26b471d", "55e4f88f711f2ac1", "62ade9b8b04e4d11",
                                   "694acb815fb9ca41", "79f44bd42b0e9045", "7b50b2f39ea28067", "816ceb27d2757ef5", "90509e0e09c3c959",
                                   "9d338b0beee52719", "a27bfe8090980cd7", "af26da805ee6963f", "b14ae83ab177b379", "b554c6dbabe4aed7",
                                   "b7e5dfc367e9fe77", "bc4b586e251a9779", "d2058cbb5afc1381", "dc5c0234bdc4a313", "df7b83086f283f73",
                                   "e274f072ae0de49f", "e45bf94a4f6a94f3", "e5fd62979a8476d5", "e88a494c1d7ce0d5", "fcf5606222833cd7",
                                   "fee89c6bf53a719d"],
        "colourMatteBecomesSolidClip()": ["783e896a233d3de3"],
        "crossDissolveBecomesTransition()": ["57a7a69398b8694c"],
        "cutsTrimsAndFormat()": ["1bb767e252aaa98b"],
        "disabledCurvesSectionAndNeutralBlobMapNothing()": ["2f7ab6f728fbad1a"],   // 2026-10-06: Lumetri summary note says wheels and hue curves are not read (wheel luma decoded, not applied)
        "displayReferred709GetsGammaCurve()": ["9e614fff3659c83d"],
        "effectsMapToClipEffects()": ["94c11c634935844e"],   // 2026-10-06: Lumetri summary note says wheels and hue curves are not read (wheel luma decoded, not applied)
        "gaussianBlurRepeatEdgePixelsMapsToTheCheckbox()": ["4ae4a45456de1b42"],
        "keyframesAreClipLocalAfterInPointAndSpeed()": ["c7bad7f356b51ec5"],
        "linearKeyAfterBezierKeepsItsInHandle()": ["7a173b799ace2143"],
        "lumetriCurvesAndVignetteImport()": ["63a842047351e8a5"],   // 2026-10-06: Lumetri summary note says wheels and hue curves are not read (wheel luma decoded, not applied)
        "lumetriNegativeOrZeroSharpenAddsNothing()": ["230559c7354ba9b7"],   // 2026-10-06: Lumetri summary note says wheels and hue curves are not read (wheel luma decoded, not applied)
        "lumetriSharpenBecomesSharpenAfterColour()": ["33292cb562490c91"],   // 2026-10-06: Lumetri summary note says wheels and hue curves are not read (wheel luma decoded, not applied)
        "mosaicTintFlipAndNoiseMap()": ["b04c4fbbeef1e4ae"],
        "motionMapsToClipAnimation()": ["c1baf412eb9f2c8e"],
        "multiTextGraphicBecomesOneGraphicsClipWithSharedEffects()": ["9a6a8d432705ac48", "49d73d49fbf8e5de", "af46cea6a1080992"],   // 2026-10-13 (8c12b916): TextStyle always encodes underline/strikethrough/overline; serialization only
        "mutedTrackStaysMuted()": ["d0138fa7c1cd7486"],
        "mutedVideoTrackBecomesHidden()": ["a30a854f90e66044"],
        "nestedSequenceBecomesNestedClip()": ["17200b4e7d6b58f9"],
        "nonUniformScaleUsesWidthParam()": ["2ea5e0a46c5ef7b1"],
        "offlineMediaGetsUnknownSizeAndReportsIt()": ["600bf67a09c8ead7"],
        "offlineStillImageStaysAStill()": ["67bf270d6d32100a"],
        "pixelAspectBecomesHorizontalScale()": ["d57dbffe5d1383b"],
        "pointTextIsPlacedByItsLayerPositionAndScale()": ["df76ca7f66147530"],   // 2026-10-13 (8c12b916): TextStyle always encodes underline/strikethrough/overline; serialization only
        "sequenceMarkersImport()": ["90465907cd6c75ac"],
        "slidePresetDropsMirrorAndMapsDirectionalBlur()": ["6bb216d3496ac2d7"],
        "speedKeepsTimelineLength()": ["6990c9e8be5d3ed"],
        "textBackgroundOffKeepsWhiteFill()": ["aad2cfd92bb3b1ab"],   // 2026-10-13 (8c12b916): TextStyle always encodes underline/strikethrough/overline; serialization only
        "textBackgroundOnCarriesOver()": ["d11fbb7ad95a1ce3"],   // 2026-10-13 (8c12b916): TextStyle always encodes underline/strikethrough/overline; serialization only
        "textGraphicBecomesTextClip()": ["8a64f0d602e57e62"],   // 2026-10-13 (8c12b916): TextStyle always encodes underline/strikethrough/overline; serialization only
        "textShadowCarriesOver()": ["6ff7c86868506858"],   // 2026-10-29: shadow angle/distance stay 0 (fields 20/34 are no angle/distance)
        "twoLineTextWithASecondStyleKeepsBothLines()": ["2f787f1eabcd8319"],   // 2026-10-13 (8c12b916): TextStyle always encodes underline/strikethrough/overline; serialization only
        "usesProbedMediaRef()": ["2e9cf89545d6aeac"],
        // 2026-10-06: clip markers (v60, snapped in clip time), Lumetri wheels (decoded, never applied) and hue curve reporting.
        "clipMarkersImportInSourceTime()": ["157a7aa0f32da7aa"],
        "clipMarkersOnAdjustmentLayerAreClipLocal()": ["f35b439d949b184e"],
        "colourWheelLumaSlidersAreDecodedButNotApplied()": ["9ffbeee103832607"],
        "colourWheelsSwitchedOffOrNeutralSayNothing()": ["758acbadd943d5bb"],
        "editedWheelColoursAndSpecularAreReportedAsDropped()": ["9f61601fc1903116", "9ffbeee103832607"],
        "flatHueCurvesSayNothingAndEditedOnesAreReported()": ["4c6cf9958ac12278"],
        "unreadableWheelBlobIsReportedAsDropped()": ["9ffbeee103832607"],
        "clipMarkersSnapToTheSequenceFrameInClipTime()": ["66518c92c03d9322"],
        // 2026-10-06: Ultra Key, Ramp, adjustment-layer carrier layers (silent only when a Shape covers the frame).
        "adjustmentLayerWithAFrameSizedCarrierIsNotALoss()": ["7da3910700683a5e"],
        "adjustmentLayerWithoutAFrameSizedCarrierIsReported()": ["6bd372677aeed7a5"],
        "rampBecomesGradient()": ["4ec24c808d0fa4e7"],
        "ultraKeyMapsHueAndSharedControls()": ["9cdb37bca9928de2"],   // Spill is Premiere id 20 (18 = Desaturate, not carried)
        "ultraKeyWithoutAKeyColourIsDropped()": ["a64c2759390a8419"],
    ]
}
