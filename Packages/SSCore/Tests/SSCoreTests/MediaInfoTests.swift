import Foundation
import Testing
@testable import SSCore

@Test func mediaRefInfoRoundTripsAndOldFilesLoad() throws {
    let info = MediaInfo(duration: Time(5, 1),
                         video: VideoTrackInfo(width: 3840, height: 2160, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                                               nominalFrameDuration: Time(1001, 60000), isVariableFrameRate: false),
                         audio: AudioTrackInfo(sampleRate: 48000, channels: 2, codec: "lpcm"))
    let ref = MediaRef(name: "a", path: "/a", fingerprint: MediaFingerprint(size: 1), info: info)
    let data = try JSONEncoder().encode(ref)
    #expect(try JSONDecoder().decode(MediaRef.self, from: data) == ref)

    // Old file: no "info" key.
    var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    obj.removeValue(forKey: "info")
    let old = try JSONSerialization.data(withJSONObject: obj)
    let loaded = try JSONDecoder().decode(MediaRef.self, from: old)
    #expect(loaded.info == nil)
    #expect(loaded.name == "a")
}
