import CoreVideo
import Foundation
import SQCore
import SQFrameCoreVideo
import SQRender
import Testing
@testable import SQLottie

/// A 100 x 100, 30 frame animation: a red 50 x 50 square in the middle that moves 0 -> 40 px right over the clip.
private let squareJSON = """
{"v":"5.7.0","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"s",
"sr":1,"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},
"p":{"a":1,"k":[{"t":0,"s":[50,50,0],"i":{"x":[1],"y":[1]},"o":{"x":[0],"y":[0]}},{"t":29,"s":[90,50,0]}]},
"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,
"shapes":[{"ty":"gr","it":[{"ty":"rc","d":1,"s":{"a":0,"k":[20,20]},"p":{"a":0,"k":[0,0]},"r":{"a":0,"k":0}},
{"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100},"r":1},
{"ty":"tr","p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],
"ip":0,"op":30,"st":0,"bm":0}]}
"""

private func request(_ json: String, at t: Time, loops: Bool = true) -> LayerRequest {
    let ref = GeneratorRef.lottie(LottieSpec(json: Data(json.utf8), sourceName: "square.json", loops: loops))
    let id = UUID()
    return LayerRequest(clip: id, media: id, track: UUID(), sourceTime: t, generator: ref, localTime: t)
}

private let canvas = SequenceFormat(width: 100, height: 100, frameDuration: Time(1, 30))

/// Linear RGBA halves of pixel (x, y).
private func pixel(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Float] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let row = CVPixelBufferGetBaseAddress(pb)!.advanced(by: y * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: Float16.self)
    return (0..<4).map { Float(row[x * 4 + $0]) }
}

private func buffer(_ l: RenderLayer) -> CVPixelBuffer? {
    if case .linearPremultiplied(let pb, _, _) = l.content { return pb.pixelBuffer }
    return nil
}

@Suite(.serialized) struct LottieRendererTests {
    @Test func drawsTheShapeAtTheRightPlace() throws {
        LottieRenderer.clearCache()
        let layer = LottieRenderer.layer(for: request(squareJSON, at: .zero), canvas: canvas)
        let pb = try #require(buffer(layer))
        #expect(CVPixelBufferGetWidth(pb) == 100 && CVPixelBufferGetHeight(pb) == 100)
        let inside = pixel(pb, 50, 50)                      // frame 0: square centered at 50,50
        #expect(inside[0] > 0.99 && inside[1] < 0.01 && inside[2] < 0.01 && inside[3] > 0.99)
        #expect(pixel(pb, 5, 5)[3] == 0)                    // outside: transparent
        // The last frame: moved right by 40 px.
        let late = try #require(buffer(LottieRenderer.layer(for: request(squareJSON, at: Time(28, 30)), canvas: canvas)))
        #expect(pixel(late, 50, 50)[3] < 0.5 || pixel(late, 85, 50)[3] > 0.99)
        #expect(pixel(late, 88, 50)[3] > 0.99)
    }

    @Test func sameFrameIsIdenticalAfterClearingTheCache() throws {
        let t = Time(10, 30)
        LottieRenderer.clearCache()
        let a = try #require(buffer(LottieRenderer.layer(for: request(squareJSON, at: t), canvas: canvas)))
        LottieRenderer.clearCache()
        let b = try #require(buffer(LottieRenderer.layer(for: request(squareJSON, at: t), canvas: canvas)))
        #expect(a !== b)
        for (x, y) in [(50, 50), (60, 50), (69, 50), (70, 50), (10, 90)] { #expect(pixel(a, x, y) == pixel(b, x, y)) }
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let n = CVPixelBufferGetBytesPerRow(a) * 100
        #expect(memcmp(CVPixelBufferGetBaseAddress(a)!, CVPixelBufferGetBaseAddress(b)!, n) == 0)
    }

    @Test func secondRequestHitsTheCache() throws {
        LottieRenderer.clearCache()
        let r = request(squareJSON, at: Time(5, 30))
        let a = try #require(buffer(LottieRenderer.layer(for: r, canvas: canvas)))
        let b = try #require(buffer(LottieRenderer.layer(for: r, canvas: canvas)))
        #expect(a === b)
    }

    @Test func rasterFitsTheCanvas() throws {
        LottieRenderer.clearCache()
        let big = SequenceFormat(width: 400, height: 200, frameDuration: Time(1, 30))
        let pb = try #require(buffer(LottieRenderer.layer(for: request(squareJSON, at: .zero), canvas: big)))
        #expect(CVPixelBufferGetWidth(pb) == 200 && CVPixelBufferGetHeight(pb) == 200)   // 100 x 100 contained in 400 x 200
    }

    @Test func unreadableFileIsOffline() {
        let layer = LottieRenderer.layer(for: request("{\"layers\":1}", at: .zero), canvas: canvas)
        if case .placeholder(let k) = layer.content { #expect(k == .offline) } else { Issue.record("expected the offline slate") }
    }
}
