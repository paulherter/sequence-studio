import Foundation
import Testing
@testable import SQCore

/// A minimal valid Lottie document: 100 x 50, 30 fps, frames 0...60 (2 s).
private func lottieJSON(w: Int = 100, h: Int = 50, fr: Double = 30, ip: Double = 0, op: Double = 60,
                        layers: String = "[]") -> Data {
    Data("""
    {"v":"5.7.0","fr":\(fr),"ip":\(ip),"op":\(op),"w":\(w),"h":\(h),"nm":"Demo","layers":\(layers)}
    """.utf8)
}

@Suite struct LottieGeneratorTests {
    @Test func parseReadsSizeAndTiming() throws {
        let info = try #require(LottieInfo.parse(lottieJSON()))
        #expect(info.width == 100 && info.height == 50)
        #expect(info.frameRate == 30 && info.inPoint == 0 && info.outPoint == 60)
        #expect(info.frameCount == 60)
        #expect(info.name == "Demo")
        #expect(info.duration == Time(2, 1))
    }

    @Test func durationIsRationalForNTSCRates() throws {
        let info = try #require(LottieInfo.parse(lottieJSON(fr: 29.97, op: 30)))
        // 30 frames at 29.97 fps = 30 * 1000/29970 s, kept exact.
        #expect(info.duration == Time(30 * 1000, 29970))
    }

    @Test func parseRejectsNonLottie() {
        #expect(LottieInfo.parse(Data("nope".utf8)) == nil)
        #expect(LottieInfo.parse(Data("{}".utf8)) == nil)
        #expect(LottieInfo.parse(Data(#"{"fr":30,"ip":0,"op":10,"w":10,"h":10}"#.utf8)) == nil)          // no layers
        #expect(LottieInfo.parse(lottieJSON(w: 0)) == nil)
        #expect(LottieInfo.parse(lottieJSON(fr: 0)) == nil)
        #expect(LottieInfo.parse(lottieJSON(ip: 10, op: 10)) == nil)                                     // empty range
        #expect(LottieInfo.parse(lottieJSON(w: LottieLimits.maxSide + 1)) == nil)
        #expect(LottieInfo.parse(Data(count: LottieLimits.maxBytes + 1)) == nil)
    }

    @Test func specRoundTripsThroughGeneratorRef() throws {
        let spec = LottieSpec(json: lottieJSON(), sourceName: "demo.json", loops: false, speed: 2)
        let ref = GeneratorRef.lottie(spec)
        #expect(ref.kind == GeneratorRef.lottie)
        #expect(ref.lottieSpec == spec)
        #expect(GeneratorRef(kind: "text", payload: ref.payload).lottieSpec == nil)
    }

    @Test func timingLoopsAndHolds() throws {
        let info = try #require(LottieInfo.parse(lottieJSON()))
        let loop = LottieSpec(json: Data(), sourceName: "", loops: true, speed: 1)
        #expect(LottieTiming.frame(localTime: .zero, info: info, spec: loop) == 0)
        #expect(LottieTiming.frame(localTime: Time(1, 1), info: info, spec: loop) == 30)
        #expect(LottieTiming.frame(localTime: Time(3, 1), info: info, spec: loop) == 30)   // 90 frames wraps to 30
        let hold = LottieSpec(json: Data(), sourceName: "", loops: false, speed: 1)
        #expect(LottieTiming.frame(localTime: Time(5, 1), info: info, spec: hold) == 59)   // last frame (op - 1)
        let fast = LottieSpec(json: Data(), sourceName: "", loops: false, speed: 2)
        #expect(LottieTiming.frame(localTime: Time(1, 2), info: info, spec: fast) == 30)
    }

    @Test func timingHonoursInPoint() throws {
        let info = try #require(LottieInfo.parse(lottieJSON(ip: 10, op: 40)))
        let loop = LottieSpec(json: Data(), sourceName: "", loops: true, speed: 1)
        #expect(LottieTiming.frame(localTime: .zero, info: info, spec: loop) == 10)
        #expect(LottieTiming.frame(localTime: Time(1, 1), info: info, spec: loop) == 10)    // 30 frames wraps to start
    }

    @Test func rasterSizeFitsCanvasWithinCap() throws {
        let info = try #require(LottieInfo.parse(lottieJSON(w: 512, h: 256)))
        let s = LottieTiming.rasterSize(info: info, canvasWidth: 1920, canvasHeight: 1080)
        #expect(s.width == 1920 && s.height == 960)                                         // contain, aspect kept
        let big = LottieTiming.rasterSize(info: info, canvasWidth: 20000, canvasHeight: 20000)
        #expect(max(big.width, big.height) <= LottieLimits.maxSide)
    }

    @Test func addLottieClipUsesAnimationLength() throws {
        let v = Track(kind: .video), a = Track(kind: .audio)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v, a])
        var p = Project(name: "P", timelines: [t])
        let id = try p.addLottieClip(json: lottieJSON(), name: "Stamp.json", in: t.id, at: Time(1, 1), track: v.id)
        let c = try #require(p.timeline(t.id)?.tracks.flatMap(\.clips).first { $0.id == id })
        #expect(c.timeline == TimeRange(start: Time(1, 1), duration: Time(2, 1)))
        #expect(c.name == "Stamp")
        #expect(c.generator?.lottieSpec?.sourceName == "Stamp.json")
        #expect(throws: LottieImportError.self) {
            try p.addLottieClip(json: Data("x".utf8), name: "x", in: t.id, at: .zero, track: v.id)
        }
    }
}
