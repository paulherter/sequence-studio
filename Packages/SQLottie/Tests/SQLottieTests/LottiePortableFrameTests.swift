import Foundation
import SQCore
import SQRender
import Testing
@testable import SQLottie

/// `LottieRenderer.portableFrame` (Windows): the Mac layer's frame as linear premultiplied floats, same size and timing.
@Suite(.serialized) struct LottiePortableFrameTests {
    /// 100 x 100, 30 frames: a red 20 x 20 square centered at (50, 50) moving to (90, 50).
    private let json = """
    {"v":"5.7.0","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,
    "nm":"s","sr":1,"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},
    "p":{"a":1,"k":[{"t":0,"s":[50,50,0],"i":{"x":[1],"y":[1]},"o":{"x":[0],"y":[0]}},{"t":29,"s":[90,50,0]}]},
    "a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,
    "shapes":[{"ty":"gr","it":[{"ty":"rc","d":1,"s":{"a":0,"k":[20,20]},"p":{"a":0,"k":[0,0]},"r":{"a":0,"k":0}},
    {"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100},"r":1},
    {"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],
    "ip":0,"op":30,"st":0,"bm":0}]}
    """
    private let canvas = SequenceFormat(width: 100, height: 100, frameDuration: Time(1, 30))
    private let clip = UUID()

    private func request(_ data: String, at t: Time) -> LayerRequest {
        let ref = GeneratorRef.lottie(LottieSpec(json: Data(data.utf8), sourceName: "square.json", loops: true))
        return LayerRequest(clip: clip, media: clip, track: UUID(), sourceTime: t, generator: ref, localTime: t)
    }

    private func alpha(_ p: [Float], _ w: Int, _ x: Int, _ y: Int) -> Float { p[(y * w + x) * 4 + 3] }

    @Test func drawsTheSquareWhereTheClipTimeSays() throws {
        LottieRenderer.clearCache()
        guard case .picture(let key, let w, let h, let px) = LottieRenderer.portableFrame(for: request(json, at: .zero),
                                                                                         canvas: canvas) else {
            Issue.record("no picture"); return
        }
        #expect(w == 100 && h == 100 && px.count == w * h * 4)
        #expect(px[(50 * w + 50) * 4] > 0.99 && px[(50 * w + 50) * 4 + 1] < 0.01 && alpha(px, w, 50, 50) > 0.99)
        #expect(alpha(px, w, 5, 5) == 0)
        #expect(LottieRenderer.frameKey(for: request(json, at: .zero), canvas: canvas) == key)
        guard case .picture(let late, _, _, let lp) = LottieRenderer.portableFrame(for: request(json, at: Time(28, 30)),
                                                                                  canvas: canvas) else {
            Issue.record("no late picture"); return
        }
        #expect(late != key)
        #expect(alpha(lp, w, 88, 50) > 0.99)
    }

    @Test func unreadableFileIsOffline() {
        guard case .offline = LottieRenderer.portableFrame(for: request("not lottie", at: .zero), canvas: canvas) else {
            Issue.record("expected offline"); return
        }
        #expect(LottieRenderer.frameKey(for: request("not lottie", at: .zero), canvas: canvas) == nil)
    }

    /// Linear premultiplied with the shapes' BT.709 inverse OETF.
    @Test func eightBitToLinearPremultiplied() {
        let p = LottieRenderer.linearPixels([255, 128, 0, 128, 9, 9, 9, 0])
        let half = Float(128) / 255
        let lin = Float(pow((half + 0.09929682680944) / 1.09929682680944, 1 / 0.45))
        #expect(abs(p[0] - half) < 1e-6 && abs(p[1] - lin * half) < 1e-6 && p[2] == 0 && abs(p[3] - half) < 1e-6)
        #expect(p[4...7].allSatisfy { $0 == 0 })
    }
}
