import Foundation
import Testing
@testable import SQCore

@Suite struct FieldOrderTests {
    private func video(_ order: FieldOrder?) -> VideoTrackInfo {
        VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                       nominalFrameDuration: Time(1, 25), isVariableFrameRate: false, fieldOrder: order)
    }

    @Test func progressiveWritesNoKeyAndOldFilesReadAsProgressive() throws {
        let data = try JSONEncoder().encode(video(nil))
        #expect(!String(decoding: data, as: UTF8.self).contains("fieldOrder"))
        let back = try JSONDecoder().decode(VideoTrackInfo.self, from: data)
        #expect(back.fieldOrder == nil)
        #expect(!back.isInterlaced)
        #expect(back == video(nil))
    }

    @Test func interlacedRoundTrips() throws {
        for order in FieldOrder.allCases {
            let back = try JSONDecoder().decode(VideoTrackInfo.self, from: JSONEncoder().encode(video(order)))
            #expect(back.fieldOrder == order)
            #expect(back.isInterlaced)
        }
    }

    @Test func unknownValueReadsAsProgressive() throws {
        let text = String(decoding: try JSONEncoder().encode(video(.topFirst)), as: UTF8.self)
            .replacingOccurrences(of: "topFirst", with: "somethingLater")
        let back = try JSONDecoder().decode(VideoTrackInfo.self, from: Data(text.utf8))
        #expect(back.fieldOrder == nil)
    }
}
