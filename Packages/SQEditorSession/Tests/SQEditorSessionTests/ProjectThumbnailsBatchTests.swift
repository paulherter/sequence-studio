import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorSession

/// Poster + clip frame of one file as one job (Color page Clips list).
@MainActor @Suite struct ProjectThumbnailsBatchTests {
    private func ref() -> MediaRef {
        let video = VideoTrackInfo(width: 320, height: 180, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 30),
                                   isVariableFrameRate: false, pixelAspect: .square)
        return MediaRef(name: "gone.mov", path: "/nowhere/\(UUID().uuidString).mov", fingerprint: MediaFingerprint(size: 1),
                        duration: Time(2, 1), info: MediaInfo(duration: Time(2, 1), video: video))
    }

    /// Both pictures of a file that cannot be read settle together: `done` fires, nothing is cached, and both failures are
    /// remembered (asking again starts no new job).
    @Test func pairOfAnUnreadableFileSettlesBothOnce() async throws {
        let t = ProjectThumbnails(pressure: nil)
        let r = ref()
        var calls = 0
        t.requestPosterAndFrame(r, frameAt: Time(1, 1), height: 60) { calls += 1 }
        for _ in 0..<400 where calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(calls == 1)
        #expect(t.cachedPoster(r.id) == nil && t.cachedFrame(r.id, at: Time(1, 1), height: 60) == nil)
        t.requestPosterAndFrame(r, frameAt: Time(1, 1), height: 60) { calls += 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }
}
