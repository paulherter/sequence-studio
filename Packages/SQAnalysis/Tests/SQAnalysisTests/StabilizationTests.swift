import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import Testing
import simd
@testable import SQAnalysis

extension VisionSuites {
@Suite struct StabilizationTests {
    private struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
    }

    /// A textured frame whose content is moved by (dx, dy) px (y down) and turned `degrees` clockwise about the center.
    private func frame(dx: Double = 0, dy: Double = 0, degrees: Double = 0, w: Int = 480, h: Int = 270,
                       seed: UInt64 = 42, blank: Bool = false) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess)
        let b = try #require(pb)
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let ctx = try #require(CGContext(data: CVPixelBufferGetBaseAddress(b), width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: CVPixelBufferGetBytesPerRow(b), space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CG is y up: a move down on screen is -dy, clockwise on screen is a negative angle.
        ctx.translateBy(x: CGFloat(Double(w) / 2 + dx), y: CGFloat(Double(h) / 2 - dy))
        ctx.rotate(by: CGFloat(-degrees * .pi / 180))
        ctx.translateBy(x: CGFloat(-Double(w) / 2), y: CGFloat(-Double(h) / 2))
        var r = LCG(s: seed)
        for _ in 0..<(blank ? 0 : 500) {
            let x = (r.next() * 2 - 0.5) * Double(w), y = (r.next() * 2 - 0.5) * Double(h), d = 4 + r.next() * 30
            ctx.setFillColor(red: r.next(), green: r.next(), blue: r.next(), alpha: 1)
            if r.next() < 0.5 {
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d * (0.5 + r.next())))
            } else {
                ctx.fill(CGRect(x: x, y: y, width: d, height: d * (0.5 + r.next())))
            }
        }
        return b
    }

    @Test func similarityFitIsExact() throws {
        let truth = CameraMotion(dx: 7, dy: -3, rotation: 4, scale: 1.05)
        let pose = CameraPose(translation: Vec2(7, -3), rotation: 4, logScale: log(1.05))
        let src = [Vec2(-50, -20), Vec2(40, -30), Vec2(30, 60), Vec2(-10, 25)]
        let m = try #require(Registration.fitSimilarity(src, src.map(pose.apply)))
        #expect(abs(m.dx - truth.dx) < 1e-9 && abs(m.dy - truth.dy) < 1e-9)
        #expect(abs(m.rotation - truth.rotation) < 1e-9 && abs(m.scale - truth.scale) < 1e-9)
    }

    @Test func visionMeasuresAMoveRightAndDown() throws {
        let m = Registration.motion(previous: try frame(), current: try frame(dx: 12, dy: 5))
        #expect(abs(m.dx - 12) < 1, "dx \(m.dx)")
        #expect(abs(m.dy - 5) < 1, "dy \(m.dy)")
        #expect(abs(m.rotation) < 0.5)
    }

    @Test func visionMeasuresAClockwiseTurn() throws {
        let m = Registration.motion(previous: try frame(), current: try frame(degrees: 3))
        #expect(abs(m.rotation - 3) < 0.5, "rotation \(m.rotation)")
        #expect(abs(m.dx) < 2 && abs(m.dy) < 2, "dx \(m.dx) dy \(m.dy)")
    }

    @Test func visionTranslationFallbackMeasuresAMoveRightAndDown() throws {
        let m = try #require(Registration.translationalMotion(previous: try frame(), current: try frame(dx: 12, dy: 5)))
        #expect(abs(m.dx - 12) < 1, "dx \(m.dx)")
        #expect(abs(m.dy - 5) < 1, "dy \(m.dy)")
        #expect(m.rotation == 0 && abs(m.scale - 1) < 1e-9)
    }

    @Test func translationFallbackHasTheSameSigns() throws {
        // A Vision translational alignment of +12 / +5 in its own (y up) pixels: the current frame's content sits 12 px
        // left and 5 px down of the previous one in screen terms.
        let m = try #require(Registration.motion(translation: CGAffineTransform(translationX: 12, y: 5), width: 480, height: 270))
        #expect(abs(m.dx - -12) < 1e-4 && abs(m.dy - 5) < 1e-4)
    }

    @Test func cacheRoundTripAndKeyChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-stab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let media = dir.appendingPathComponent("clip.mov")
        try Data("x".utf8).write(to: media)
        let cache = StabilizationCache(cachesDirectory: dir, disk: .unchecked)
        let range = TimeRange(start: .zero, duration: Time(2, 1))
        let key = try #require(cache.key(url: media, range: range, maxDimension: 512))
        #expect(cache.key(url: media, range: TimeRange(start: .zero, duration: Time(3, 1)), maxDimension: 512) != key)
        #expect(cache.key(url: media, range: range, maxDimension: 256) != key)
        #expect(cache.load(key: key) == nil)
        let a = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: [.zero, Time(1, 30)],
                                      motions: [.identity, CameraMotion(dx: 1, dy: 2, rotation: 0.1, scale: 1)])
        cache.store(a, key: key)
        #expect(cache.load(key: key) == a)
        #expect(cache.key(url: dir.appendingPathComponent("missing.mov"), range: range, maxDimension: 512) == nil)
    }

    @Test func cacheDropsOldVersionsCapsSizeAndRespectsTheDiskFloor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-stab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: [.zero, Time(1, 30)],
                                      motions: [.identity, CameraMotion(dx: 1, dy: 2, rotation: 0.1, scale: 1)])
        let size = try JSONEncoder().encode(a).count
        let cache = StabilizationCache(cachesDirectory: dir, limitBytes: size * 2 + size / 2, disk: .unchecked)
        try FileManager.default.createDirectory(at: cache.root, withIntermediateDirectories: true)
        let old = cache.root.appendingPathComponent("old.json")
        try Data(#"{"version":0}"#.utf8).write(to: old)
        cache.store(a, key: "k1")
        #expect(!FileManager.default.fileExists(atPath: old.path))          // older cache version swept on first store
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -300)], ofItemAtPath: cache.root.appendingPathComponent("k1.json").path)
        cache.store(a, key: "k2")
        cache.store(a, key: "k3")                                           // three files exceed the cap: the oldest goes
        #expect(cache.load(key: "k1") == nil)
        #expect(cache.load(key: "k2") == a && cache.load(key: "k3") == a)
        // Below the free-space floor nothing is written and the cache is emptied.
        let low = StabilizationCache(cachesDirectory: dir, disk: CacheDiskPolicy(space: { _ in (free: 1 << 30, total: 256 << 30) }))
        low.store(a, key: "k4")
        #expect(low.load(key: "k4") == nil && low.load(key: "k2") == nil)
    }

    @Test func similarityWarpHasNoRestPerspectiveWarpHasOne() throws {
        // A turn + shift + zoom (Vision pixels, y up) is a similarity: nothing left after the fit.
        let a = Float(cos(0.02) * 1.01), b = Float(sin(0.02) * 1.01)
        var sim = matrix_identity_float3x3
        sim.columns.0 = SIMD3(a, b, 0); sim.columns.1 = SIMD3(-b, a, 0); sim.columns.2 = SIMD3(3, -2, 1)
        #expect(try #require(Registration.nonSimilarity(visionWarp: sim, width: 512, height: 288)) < 0.01)
        // A keystone (what Vision fits to a blank wall or a blurred frame): a rest of several px.
        var keystone = matrix_identity_float3x3
        keystone.columns.0 = SIMD3(1, 0, 0.0004)
        let rest = try #require(Registration.nonSimilarity(visionWarp: keystone, width: 512, height: 288))
        #expect(rest > 2, "rest \(rest)")
    }

    @Test func homographyWithALargeRestIsNotTrusted() {
        // Measured on hand-held iPhone/Sony footage at 512 px: a rest over 1 px goes with ~1.8 px forward/backward
        // disagreement, under it ~0.04 px. The limit scales with the analysis size.
        #expect(Registration.homographyTrusted(rest: 0.8, width: 512, height: 288))
        #expect(!Registration.homographyTrusted(rest: 1.2, width: 288, height: 512))
        #expect(Registration.homographyTrusted(rest: 1.8, width: 1024, height: 576))
    }

    @Test func analysisFrameHasTheShownShape() throws {
        typealias A = VisionStabilizationAnalyzer
        func size(_ w: Int, _ h: Int, _ p: PixelAspect = .square, turned: Bool = false, max m: Int = 960) -> [Int]? {
            A.shrunkSize(width: w, height: h, pixelAspect: p, quarterTurned: turned, maxDimension: m).map { [$0.width, $0.height] }
        }
        // Square pixels: as before (long side capped, never enlarged, a quarter turn swaps the sides).
        #expect(size(1920, 1080) == [960, 540])
        #expect(size(480, 270) == [480, 270])
        #expect(size(1920, 1080, turned: true) == [540, 960])
        // A 2x anamorphic frame is analyzed as it is shown (twice as wide as high-per-pixel), not squeezed; the stored
        // long side is the cap, so nothing is invented.
        let two = try #require(PixelAspect(2, 1))
        #expect(size(960, 540, two) == [960, 270])
        #expect(size(400, 300, two) == [400, 150])
        #expect(size(960, 540, two, turned: true) == [270, 960])
        // Narrow pixels (NTSC DV 10:11): the picture gets narrower.
        #expect(size(720, 480, try #require(PixelAspect(10, 11))) == [655, 480])
        #expect(size(0, 480) == nil)

        // The buffer: a clean aperture tag crops nothing (the app draws the whole decoded frame), so a mark keeps its
        // frame fractions; squeezed pixels change the shape only.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let b = try #require(pb)
        CVPixelBufferLockBaseAddress(b, [])
        let base = try #require(CVPixelBufferGetBaseAddress(b)).assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<240 { for x in 0..<320 {
            let on: UInt8 = x < 32 && y < 24 ? 255 : 0                       // mark: the top left tenth
            for c in 0..<3 { base[y * row + x * 4 + c] = on }
            base[y * row + x * 4 + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(b, [])
        CVBufferSetAttachment(b, kCVImageBufferCleanApertureKey, [
            kCVImageBufferCleanApertureWidthKey: 240, kCVImageBufferCleanApertureHeightKey: 180,
            kCVImageBufferCleanApertureHorizontalOffsetKey: 0, kCVImageBufferCleanApertureVerticalOffsetKey: 0,
        ] as CFDictionary, .shouldPropagate)
        func mark(_ out: CVPixelBuffer) -> (w: Int, h: Int, right: Double, bottom: Double) {
            CVPixelBufferLockBaseAddress(out, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
            let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out), r = CVPixelBufferGetBytesPerRow(out)
            let p = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
            var right = 0, bottom = 0
            for x in 0..<w where p[x * 4] > 127 { right = x + 1 }
            for y in 0..<h where p[y * r] > 127 { bottom = y + 1 }
            return (w, h, Double(right) / Double(w), Double(bottom) / Double(h))
        }
        let context = CIContext()
        let plain = mark(try #require(A.shrink(b, orientation: .up, maxDimension: 960, context: context)))
        #expect(plain.w == 320 && plain.h == 240)
        #expect(abs(plain.right - 0.1) < 0.01 && abs(plain.bottom - 0.1) < 0.01)
        let wide = mark(try #require(A.shrink(b, orientation: .up, maxDimension: 960, pixelAspect: two, context: context)))
        #expect(wide.w == 320 && wide.h == 120)
        #expect(abs(wide.right - 0.1) < 0.01 && abs(wide.bottom - 0.1) < 0.02)
    }

    @Test func decoderScalesToTheAnalysisSize() {
        // 4K (stored landscape, shown portrait: orientation is applied later) -> long side 512, even sides, aspect kept.
        let s = VisionStabilizationAnalyzer.decodeSize(natural: CGSize(width: 3840, height: 2160), maxDimension: 512)
        #expect(s?.width == 512 && s?.height == 288)
        let p = VisionStabilizationAnalyzer.decodeSize(natural: CGSize(width: 1080, height: 1920), maxDimension: 512)
        #expect(p?.width == 288 && p?.height == 512)
        // Already small, or no size: decode as is.
        #expect(VisionStabilizationAnalyzer.decodeSize(natural: CGSize(width: 480, height: 270), maxDimension: 512) == nil)
        #expect(VisionStabilizationAnalyzer.decodeSize(natural: .zero, maxDimension: 512) == nil)
    }

    // MARK: W9.7 (2a/2b) photometric check, confidence, cuts

    private func gray(_ pb: CVPixelBuffer) throws -> GrayFrame { try #require(GrayFrame(halving: pb)) }

    @Test func photometricCheckMeasuresAMoveAndATurnOnItsOwn() throws {
        // Gray frames are half size: 12 / 5 px of the 480 px frame are 6 / 2.5 px there.
        let m = try #require(PhotometricRegistration.register(previous: try gray(try frame()), current: try gray(try frame(dx: 12, dy: 5))))
        #expect(m.converged && m.texture >= PhotometricRegistration.minTexture, "texture \(m.texture)")
        #expect(abs(m.motion.dx - 6) < 0.3 && abs(m.motion.dy - 2.5) < 0.3, "\(m.motion)")
        let t = try #require(PhotometricRegistration.register(previous: try gray(try frame()), current: try gray(try frame(degrees: 3))))
        #expect(abs(t.motion.rotation - 3) < 0.3, "\(t.motion)")
        #expect(abs(t.motion.dx) < 0.5 && abs(t.motion.dy) < 0.5)
    }

    @Test func aBlankFrameHasNoTextureAndNoConfidence() throws {
        let check = PhotometricRegistration.register(previous: try gray(try frame(blank: true)), current: try gray(try frame(dx: 3, blank: true)))
        #expect((check?.texture ?? 0) < PhotometricRegistration.minTexture)
        #expect(PhotometricRegistration.confidence(vision: CameraMotion(dx: 3), check: check, checkInSource: check?.motion,
                                                   pictureWidth: 480, pictureHeight: 270) == 0)
    }

    @Test func confidenceFollowsTheAgreementOfBothRegistrations() throws {
        let check = try #require(PhotometricRegistration.register(previous: try gray(try frame()), current: try gray(try frame(dx: 12, dy: 5))))
        let inSource = Registration.scaled(check.motion, by: 2)
        let agree = PhotometricRegistration.confidence(vision: CameraMotion(dx: 12, dy: 5), check: check, checkInSource: inSource,
                                                       pictureWidth: 480, pictureHeight: 270)
        let disagree = PhotometricRegistration.confidence(vision: CameraMotion(dx: 16, dy: 2), check: check, checkInSource: inSource,
                                                          pictureWidth: 480, pictureHeight: 270)
        #expect(agree > 0.9, "agree \(agree)")
        #expect(disagree == 0)
    }

    private func pass(_ frames: [CVPixelBuffer]) -> StabilizationAnalysis {
        let p = VisionStabilizationAnalyzer.Pass(maxDimension: 512, pictureWidth: 480, pictureHeight: 270, start: 0, total: 1,
                                                 progress: nil)
        for (k, f) in frames.enumerated() { p.add(f, pts: CMTime(value: CMTimeValue(k), timescale: 30), orientation: .up) }
        return p.finish()
    }

    @Test func aCutToAnotherShotRestartsThePath() throws {
        // A hand-held shot of one scene, then a cut to another scene with the same kind of colors.
        var r = LCG(s: 9)
        var frames: [CVPixelBuffer] = []
        for _ in 0..<14 { frames.append(try frame(dx: 4 * r.next(), dy: 4 * r.next(), seed: 42)) }
        for _ in 0..<14 { frames.append(try frame(dx: 4 * r.next(), dy: 4 * r.next(), seed: 7)) }
        let a = pass(frames)
        #expect(a.cuts == [14], "cuts \(a.cuts)")
        #expect(a.confidence.count == 28 && a.checks.count == 28)
        // Within each shot both registrations agree.
        let trusted = a.confidence.indices.filter { $0 != 14 && a.confidence[$0] >= 0.5 }.count
        #expect(trusted >= 24, "trusted \(trusted) of 27")
    }

    @Test func sixtyFpsIsRegisteredAtThirty() throws {
        var r = LCG(s: 5)
        let frames = try (0..<12).map { _ in try frame(dx: 3 * r.next(), dy: 3 * r.next()) }
        let p = VisionStabilizationAnalyzer.Pass(maxDimension: 512, minFrameInterval: VisionStabilizationAnalyzer.defaultMinFrameInterval,
                                                 pictureWidth: 480, pictureHeight: 270, start: 0, total: 1, progress: nil)
        for (k, f) in frames.enumerated() { p.add(f, pts: CMTime(value: CMTimeValue(1001 * k), timescale: 60000), orientation: .up) }
        let a = p.finish()
        #expect(a.frameTimes.count == 6 && a.motions.count == 6)
        #expect(a.frameTimes[1] == Time(2002, 60000))
        // The source's own frame interval is kept (a sensor cannot read longer than it): 1/59.94, not the analyzed 1/29.97.
        #expect(abs(a.sourceFrameInterval - 1001.0 / 60000) < 1e-9)
        let fast = VisionStabilizationAnalyzer.Pass(maxDimension: 512, minFrameInterval: VisionStabilizationAnalyzer.defaultMinFrameInterval,
                                                    pictureWidth: 480, pictureHeight: 270, start: 0, total: 1, progress: nil)
        for (k, f) in frames.enumerated() { fast.add(f, pts: CMTime(value: CMTimeValue(k), timescale: 120), orientation: .up) }
        let b = fast.finish()
        #expect(b.frameTimes.count == 4 && b.frameTimes[1] == Time(3, 120))
        #expect(abs(b.sourceFrameInterval - 1.0 / 120) < 1e-9)
        #expect(abs(RollingShutter.estimate(b).readout) <= 1.0 / 120 + 1e-12)
        // 30 fps keeps every frame.
        let q = VisionStabilizationAnalyzer.Pass(maxDimension: 512, minFrameInterval: VisionStabilizationAnalyzer.defaultMinFrameInterval,
                                                 pictureWidth: 480, pictureHeight: 270, start: 0, total: 1, progress: nil)
        for (k, f) in frames.prefix(4).enumerated() { q.add(f, pts: CMTime(value: CMTimeValue(1001 * k), timescale: 30000), orientation: .up) }
        let c = q.finish()
        #expect(c.frameTimes.count == 4 && abs(c.sourceFrameInterval - 1001.0 / 30000) < 1e-9)
    }

    /// Pixel aspect 1.33 (480 x 270 stored, shown 640 wide): a shift of 6 px right and 4 px down in the stored frame is
    /// 8 and 4 px in the picture. The rolling sample has its own vertical factor (one factor gave 5.33 down).
    @Test func theRollingSampleOfAnAnamorphicClipIsInPicturePixels() throws {
        let p = VisionStabilizationAnalyzer.Pass(maxDimension: 512, pictureWidth: 640, pictureHeight: 270, start: 0, total: 1,
                                                 progress: nil)
        p.add(try frame(), pts: CMTime(value: 0, timescale: 30), orientation: .up)
        p.add(try frame(dx: 6, dy: 4), pts: CMTime(value: 1, timescale: 30), orientation: .up)
        let s = try #require(p.finish().rolling.last ?? nil)
        #expect(abs(s.shiftX - 8) < 0.5 && abs(s.shiftY - 4) < 0.4, "shift \(s.shiftX), \(s.shiftY)")
        #expect(abs(s.slopeX) < 1.5 && abs(s.slopeY) < 1.5, "slope \(s.slopeX), \(s.slopeY)")
    }

    /// The camera motion itself (what Stabilizer smooths) and its photometric check are in picture pixels on both axes.
    @Test func theCameraMotionOfAnAnamorphicClipIsInPicturePixels() throws {
        let p = VisionStabilizationAnalyzer.Pass(maxDimension: 512, pictureWidth: 960, pictureHeight: 270, start: 0, total: 1,
                                                 progress: nil)
        p.add(try frame(), pts: CMTime(value: 0, timescale: 30), orientation: .up)
        p.add(try frame(dx: 6, dy: 4), pts: CMTime(value: 1, timescale: 30), orientation: .up)
        let a = p.finish()
        let m = a.motions[1]
        #expect(abs(m.dx - 12) < 0.6 && abs(m.dy - 4) < 0.5, "motion \(m.dx), \(m.dy)")
        let c = try #require(a.checks[1])
        #expect(abs(c.dx - 12) < 1 && abs(c.dy - 4) < 0.8, "check \(c.dx), \(c.dy)")
    }

    /// A stored analysis from before Rolling Shutter was measured still answers every request that does not need the
    /// per-row motion; only a Stabilizer with the option on has the clip measured again.
    @Test func anOlderCacheIsOnlyMeasuredAgainForRollingShutter() {
        let times = (0..<3).map { Time(Int64($0), 30) }
        let old = StabilizationAnalysis(pictureWidth: 1920, pictureHeight: 1080, frameTimes: times,
                                        motions: [CameraMotion](repeating: .identity, count: 3))
        var new = old
        new.rolling = [nil, RollingShutterSample(shiftX: 1, shiftY: 0, slopeX: 0, slopeY: 0), nil]
        typealias A = VisionStabilizationAnalyzer
        #expect(A.answers(old, pictureWidth: 1920, pictureHeight: 1080, rolling: false))
        #expect(!A.answers(old, pictureWidth: 1920, pictureHeight: 1080, rolling: true))
        #expect(A.answers(new, pictureWidth: 1920, pictureHeight: 1080, rolling: true))
        #expect(A.answers(new, pictureWidth: 1920, pictureHeight: 1080, rolling: false))
        #expect(!A.answers(new, pictureWidth: 1280, pictureHeight: 1080, rolling: false))
    }

    @Test func aShakyShotWithoutCutsHasNone() throws {
        var r = LCG(s: 3)
        let frames = try (0..<24).map { _ in try frame(dx: 6 * r.next(), dy: 6 * r.next(), degrees: r.next() - 0.5) }
        #expect(pass(frames).cuts.isEmpty)
    }

    @Test func implausibleJumpsAreRejected() {
        #expect(!Registration.plausible(CameraMotion(dx: 300), 480, 270))
        #expect(!Registration.plausible(CameraMotion(rotation: 45), 480, 270))
        #expect(Registration.plausible(CameraMotion(dx: 10, dy: -4, rotation: 1, scale: 1.01), 480, 270))
    }

    @Test func featureTrackerMeasuresShiftAndTurnSubPixel() throws {
        let a = try #require(GrayFrame(fullSize: try frame()))
        let b = try #require(GrayFrame(fullSize: try frame(dx: 7.3, dy: -4.1, degrees: 1.5)))
        let pa = try #require(FeaturePyramid(a)), pb = try #require(FeaturePyramid(b))
        let m = try #require(FeatureTracker.register(previous: pa, current: pb))
        #expect(abs(m.motion.dx - 7.3) < 0.3 && abs(m.motion.dy + 4.1) < 0.3, "motion \(m.motion)")
        #expect(abs(m.motion.rotation - 1.5) < 0.1, "rotation \(m.motion.rotation)")
        #expect(m.confidence > 0.5)
    }

    @Test func featureTrackerSaysNothingOnABlankFrame() throws {
        let a = try #require(GrayFrame(fullSize: try frame(blank: true)))
        let pa = try #require(FeaturePyramid(a))
        let m = FeatureTracker.register(previous: pa, current: pa)
        #expect(m == nil || m!.confidence < 0.5)
    }
}
}

/// Homography analysis on synthetic shaky sequences (point pairs; no video needed).
@Suite struct HomographyAnalysisTests {
    struct Rng { var s = SplitMix(seed: 42); mutating func u() -> Double { Double(s.next() % 1_000_000) / 1_000_000 * 2 - 1 } }

    /// A camera shake with perspective: turn, zoom, shift and a small projective tilt (px at 640x360).
    static func shake(_ r: inout Rng) -> Homography {
        let a = r.u() * 0.03, z = 1 + r.u() * 0.02
        return Homography(h: [z * cos(a), -z * sin(a), r.u() * 8, z * sin(a), z * cos(a), r.u() * 8, r.u() * 4e-4, r.u() * 4e-4, 1])
    }

    static func points(_ r: inout Rng, _ n: Int) -> [Vec2] { (0..<n).map { _ in Vec2(r.u() * 300, r.u() * 170) } }

    /// RMS px between two motions over the picture.
    static func gap(_ m: CameraMotion, _ ideal: CameraMotion) -> Double {
        var s = 0.0, c = 0.0
        for i in -2...2 { for j in -2...2 {
            let p = Vec2(Double(i) * 150, Double(j) * 85)
            let d = m.pose.apply(p) - ideal.pose.apply(p)
            s += d.x * d.x + d.y * d.y; c += 1
        } }
        return (s / c).squareRoot()
    }

    @Test func fitRecoversAnExactHomography() throws {
        var r = Rng(); let h = Self.shake(&r)
        let src = Self.points(&r, 30), dst = src.map { h.apply($0)! }
        let f = try #require(Homography.fit(src, dst))
        for p in src { let d = f.apply(p)! - h.apply(p)!; #expect(d.length < 1e-6) }
    }

    @Test func collinearPointsHaveNoHomography() {
        let src = (0..<8).map { Vec2(Double($0) * 10, Double($0) * 5) }
        #expect(Homography.fit(src, src) == nil)
    }

    @Test func homographyBeatsSimilarityOnShakeWithPerspectiveAndOutliers() throws {
        var r = Rng()
        var simErr = 0.0, homErr = 0.0, driftSim = 0.0, driftHom = 0.0, used = 0
        var accTrue = Vec2(200, 100), accSim = accTrue, accHom = accTrue      // one content point followed through the chain
        let frames = 40
        for _ in 0..<frames {
            let h = Self.shake(&r)
            let src = Self.points(&r, 120)
            var dst = src.map { h.apply($0)! + Vec2(r.u() * 0.15, r.u() * 0.15) }
            for i in 0..<36 { dst[i] = dst[i] + Vec2(r.u() * 25, r.u() * 25) }      // a moving subject: 30 % outliers
            let sim = try #require(FeatureTracker.ransacSimilarity(src, dst, threshold: 1.0))
            let fit = try #require(FeatureTracker.fitMotion(src, dst, threshold: 1.0, halfWidth: 320, halfHeight: 180))
            if fit.homography { used += 1 }
            // The reference is the best similarity of the true map; the path error is how far each accumulated path drifts.
            let ideal = try #require(h.similarity(halfWidth: 320, halfHeight: 180))
            simErr += Self.gap(sim.motion, ideal); homErr += Self.gap(fit.motion, ideal)
            accTrue = ideal.pose.apply(accTrue); accSim = sim.motion.pose.apply(accSim); accHom = fit.motion.pose.apply(accHom)
            driftSim += (accSim - accTrue).length
            driftHom += (accHom - accTrue).length
        }
        let n = Double(frames)
        NSLog("residual shake px per pair: similarity %.3f -> homography %.3f; path drift %.2f -> %.2f", simErr / n, homErr / n, driftSim / n, driftHom / n)
        #expect(used > frames * 3 / 4, "residual \(simErr / n) -> \(homErr / n); drift \(driftSim / n) -> \(driftHom / n)")
        #expect(homErr < simErr * 0.6, "homography \(homErr / n) px vs similarity \(simErr / n) px")
        #expect(driftHom < driftSim)
    }

    @Test func theResidualIsWhatTheSimilarityLeavesOfTheHomography() throws {
        var r = Rng()
        var checked = 0
        for _ in 0..<12 {
            let h = Self.shake(&r)
            let src = Self.points(&r, 120)
            let fit = try #require(FeatureTracker.fitMotion(src, src.map { h.apply($0)! }, threshold: 1.0, halfWidth: 320, halfHeight: 180))
            guard fit.homography else { continue }
            let res = try #require(fit.residual)
            #expect(!res.isZero)
            // Camera similarity after the residual gives the pair's map back (H = S R), to a fraction of a pixel.
            for p in [Vec2(-300, -170), Vec2(290, 160), Vec2(0, 0), Vec2(-250, 150)] {
                let got = fit.motion.pose.apply(res.map(p)), want = h.apply(p)!
                #expect((got - want).length < 0.05, "at \(p): \(got) vs \(want)")
            }
            checked += 1
        }
        #expect(checked > 8)
        // A similarity fit carries none.
        let pose = CameraPose(translation: Vec2(5, -3), rotation: 1, logScale: 0.01)
        let src = Self.points(&r, 80)
        #expect(try #require(FeatureTracker.fitMotion(src, src.map { pose.apply($0) }, threshold: 1.0, halfWidth: 320, halfHeight: 180)).residual == nil)
    }

    @Test func fewPointsKeepTheSimilarity() throws {
        var r = Rng()
        let src = Self.points(&r, 18), h = Self.shake(&r)
        let fit = try #require(FeatureTracker.fitMotion(src, src.map { h.apply($0)! }, threshold: 1.0, halfWidth: 320, halfHeight: 180))
        #expect(!fit.homography)
    }

    @Test func aPureSimilarityStaysASimilarity() throws {
        var r = Rng()
        let pose = CameraPose(translation: Vec2(5, -3), rotation: 1, logScale: 0.01)
        let src = Self.points(&r, 80)
        let fit = try #require(FeatureTracker.fitMotion(src, src.map { pose.apply($0) }, threshold: 1.0, halfWidth: 320, halfHeight: 180))
        #expect(!fit.homography)
        #expect(abs(fit.motion.dx - 5) < 0.05 && abs(fit.motion.rotation - 1) < 0.02)
    }

    @Test func analysisVersionInvalidatesSimilarityCaches() {
        #expect(StabilizationAnalysis.currentVersion >= 7)
    }
}
