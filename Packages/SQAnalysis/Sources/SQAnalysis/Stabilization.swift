import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Synchronization
import SQCore
import SQMedia
import Vision

// W9.7 Stabilizer analysis: Vision image registration between consecutive frames of a source range -> one `CameraMotion`
// per frame (SQCore turns them into the path, smoothing and the stage keys). Frames are read in order with an
// AVAssetReader, turned upright and shrunk to `maxDimension` before Vision sees them; motions are converted to px of the
// upright source picture. Results are cached on disk per file (path, size, date) and range (`StabilizationCache`).


extension StabilizationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .unreadable: "The file could not be read."
        }
    }
}

// MARK: - Registration maths

extension Registration {

    /// The content motion previous -> current frame from Vision's warp (pixel coordinates of a `width` x `height` image,
    /// origin bottom-left, y up). Vision's matrix maps the targeted (current) image into the handler's (previous) image,
    /// so the motion is its inverse; measured as point pairs in our frame (center origin, y down) and fitted.
    static func motion(visionWarp m: simd_float3x3, width: Int, height: Int) -> CameraMotion? {
        let w = Double(width), h = Double(height)
        func vision(_ p: Vec2) -> Vec2 { Vec2(p.x + w / 2, h / 2 - p.y) }           // ours -> Vision pixels
        func ours(_ v: Vec2) -> Vec2 { Vec2(v.x - w / 2, h / 2 - v.y) }
        func warp(_ v: Vec2) -> Vec2? {
            let x = Double(m.columns.0.x) * v.x + Double(m.columns.1.x) * v.y + Double(m.columns.2.x)
            let y = Double(m.columns.0.y) * v.x + Double(m.columns.1.y) * v.y + Double(m.columns.2.y)
            let z = Double(m.columns.0.z) * v.x + Double(m.columns.1.z) * v.y + Double(m.columns.2.z)
            guard abs(z) > 1e-9 else { return nil }
            return Vec2(x / z, y / z)
        }
        // Points of the current frame and where they were in the previous one: fit previous -> current.
        let cur = [Vec2(-w / 4, -h / 4), Vec2(w / 4, -h / 4), Vec2(w / 4, h / 4), Vec2(-w / 4, h / 4), .zero]
        var prev: [Vec2] = []
        for p in cur {
            guard let q = warp(vision(p)) else { return nil }
            prev.append(ours(q))
        }
        return fitSimilarity(prev, cur)
    }

    /// How far Vision's warp is from any similarity: RMS px of the 5 measuring points after the similarity fit. A
    /// hand-held camera between two frames is close to a similarity; a large rest is a homography Vision fitted to noise
    /// (low texture, blur, a moving subject).
    static func nonSimilarity(visionWarp m: simd_float3x3, width: Int, height: Int) -> Double? {
        let w = Double(width), h = Double(height)
        let cur = [Vec2(-w / 4, -h / 4), Vec2(w / 4, -h / 4), Vec2(w / 4, h / 4), Vec2(-w / 4, h / 4), .zero]
        var prev: [Vec2] = []
        for p in cur {
            let v = Vec2(p.x + w / 2, h / 2 - p.y)
            let x = Double(m.columns.0.x) * v.x + Double(m.columns.1.x) * v.y + Double(m.columns.2.x)
            let y = Double(m.columns.0.y) * v.x + Double(m.columns.1.y) * v.y + Double(m.columns.2.y)
            let z = Double(m.columns.0.z) * v.x + Double(m.columns.1.z) * v.y + Double(m.columns.2.z)
            guard abs(z) > 1e-9 else { return nil }
            prev.append(Vec2(x / z - w / 2, h / 2 - y / z))
        }
        guard let f = fitSimilarity(prev, cur) else { return nil }
        let pose = CameraPose(translation: Vec2(f.dx, f.dy), rotation: f.rotation, logScale: log(f.scale))
        var s = 0.0
        for i in cur.indices { let d = pose.apply(prev[i]) - cur[i]; s += d.x * d.x + d.y * d.y }
        return (s / Double(cur.count)).squareRoot()
    }

    static func motion(translation t: CGAffineTransform, width: Int, height: Int) -> CameraMotion? {
        var m = matrix_identity_float3x3
        m.columns.0 = SIMD3(Float(t.a), Float(t.b), 0)
        m.columns.1 = SIMD3(Float(t.c), Float(t.d), 0)
        m.columns.2 = SIMD3(Float(t.tx), Float(t.ty), 1)
        return motion(visionWarp: m, width: width, height: height)
    }

    /// Motion previous -> current between two small upright frames: homography (turn and zoom too), translation as the
    /// fallback; identity when neither finds a match (a cut, a black frame).
    static func motion(previous: CVPixelBuffer, current: CVPixelBuffer) -> CameraMotion {
        matched(previous: previous, current: current) ?? .identity
    }

    /// nil when neither registration finds a plausible match: the frames are not the same shot (a cut).
    /// Untrusted homographies (`homographyTrusted`) are still used here: replacing them by Vision's whole-pixel
    /// translation, or dropping their turn and zoom, measured no better on real footage (DECISIONS 2026-10-04).
    static func matched(previous: CVPixelBuffer, current: CVPixelBuffer) -> CameraMotion? {
        homographicMotion(previous: previous, current: current) ?? translationalMotion(previous: previous, current: current)
    }

    /// Vision homography, reduced to a similarity; nil when Vision finds none or it is implausible.
    static func homographicMotion(previous: CVPixelBuffer, current: CVPixelBuffer) -> CameraMotion? {
        homography(previous: previous, current: current)?.motion
    }

    /// Vision homography reduced to a similarity plus its non-similarity rest (px); nil when none or implausible.
    static func homography(previous: CVPixelBuffer, current: CVPixelBuffer) -> (motion: CameraMotion, rest: Double)? {
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: current, options: [:])
        guard (try? VNImageRequestHandler(cvPixelBuffer: previous, options: [:]).perform([request])) != nil,
              let o = request.results?.first, let m = motion(visionWarp: o.warpTransform, width: w, height: h),
              let rest = nonSimilarity(visionWarp: o.warpTransform, width: w, height: h), plausible(m, w, h) else { return nil }
        return (m, rest)
    }

    /// Largest non-similarity rest of a trusted homography, px per 512 px of the long side. Measured 2026-10-04 on
    /// hand-held iPhone/Sony footage (EngineBench stabilize-probe): above it the forward and backward registrations of
    /// the same pair disagree by ~1.8 px (median), below it by ~0.04 px; 5-20 % of frames are above on textured shots,
    /// 60-75 % on a blank wall. EngineBench measures the residual shake with trusted pairs only.
    static let maxHomographyRest = 1.0

    static func homographyTrusted(rest: Double, width: Int, height: Int) -> Bool {
        rest.isFinite && rest <= maxHomographyRest * Double(max(width, height)) / 512
    }

    /// Vision translational alignment (the fallback); nil when Vision finds none or it is implausible.
    static func translationalMotion(previous: CVPixelBuffer, current: CVPixelBuffer) -> CameraMotion? {
        let w = CVPixelBufferGetWidth(current), h = CVPixelBufferGetHeight(current)
        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: current, options: [:])
        guard (try? VNImageRequestHandler(cvPixelBuffer: previous, options: [:]).perform([request])) != nil,
              let o = request.results?.first, let m = motion(translation: o.alignmentTransform, width: w, height: h),
              plausible(m, w, h) else { return nil }
        return m
    }
}

// MARK: - Analyzer

/// Vision analysis of one media file, cached. Frames are read sequentially (AVAssetReader), so a whole clip is one pass.
public struct VisionStabilizationAnalyzer: StabilizationAnalyzing {
    public let url: URL
    public let maxDimension: Int
    public let cache: StabilizationCache?
    /// Frames closer than this (seconds) to the last analyzed one are skipped: 50/60 fps footage is registered at 25/30
    /// fps and the frames between get interpolated corrections (`Stabilizer.correction(_:_:at:)`). Every registration
    /// adds its own noise to the camera path, so twice the pairs per second double the noise the smoothing window
    /// collects: 60 fps iPhone shots got shakier after correction at full rate (W9.7 2c, the design notes).
    public let minFrameInterval: Double
    public static let defaultMinFrameInterval = 0.024
    /// The rebuilt analysis registers every frame (tracked features are far less noisy than one dense registration per
    /// pair, and 60 fps shake above 15 Hz can only be corrected with every frame); `defaultMinFrameInterval` is the old
    /// thinning, kept for slow Macs and tests.
    public static let everyFrame = 0.0
    /// Analysis frame long side: 720 px on the short side of a 16:9 picture (docs/research/stabilization/R2 section 2).
    // shortcut: long side 1280 instead of short side 720 (same for 16:9, a little smaller for 4:3 and taller than needed for
    // ultra wide), upgrade when `shrunkSize` can take a short side.
    public static let defaultMaxDimension = 1280
    /// The media item's `VideoTrackInfo.deinterlaceFieldOrder`: frames are registered deinterlaced (nil = as stored).
    public let deinterlace: FieldOrder?

    public init(url: URL, maxDimension: Int = VisionStabilizationAnalyzer.defaultMaxDimension, cache: StabilizationCache? = StabilizationCache(),
                minFrameInterval: Double = VisionStabilizationAnalyzer.everyFrame, deinterlace: FieldOrder? = nil) {
        self.url = url; self.maxDimension = maxDimension; self.cache = cache; self.minFrameInterval = minFrameInterval
        self.deinterlace = deinterlace
    }

    public func analyze(sourceRange: TimeRange, pictureWidth: Int, pictureHeight: Int,
                        progress: (@Sendable (Double) -> Void)?) async throws -> StabilizationAnalysis {
        try await analyze(sourceRange: sourceRange, pictureWidth: pictureWidth, pictureHeight: pictureHeight, rolling: false,
                          progress: progress)
    }

    /// Whether a stored analysis answers a request: same picture size, and the per-row motion only when the Rolling
    /// Shutter option asks for it (a result from before it was measured still plans every Stabilizer without the
    /// option; decoding the clip again for nothing would cost minutes).
    static func answers(_ hit: StabilizationAnalysis, pictureWidth: Int, pictureHeight: Int, rolling: Bool) -> Bool {
        hit.pictureWidth == pictureWidth && hit.pictureHeight == pictureHeight
            && (!rolling || !hit.rolling.isEmpty || hit.frameTimes.count < 2)
    }

    public func analyze(sourceRange: TimeRange, pictureWidth: Int, pictureHeight: Int, rolling: Bool,
                        progress: (@Sendable (Double) -> Void)?) async throws -> StabilizationAnalysis {
        let key = cache.flatMap { $0.key(url: url, range: sourceRange, maxDimension: maxDimension, deinterlace: deinterlace) }
        if let cache, let key, let hit = cache.load(key: key),
           Self.answers(hit, pictureWidth: pictureWidth, pictureHeight: pictureHeight, rolling: rolling) {
            progress?(1)
            return hit
        }
        let result = try await measure(sourceRange: sourceRange, pictureWidth: pictureWidth, pictureHeight: pictureHeight,
                                       progress: progress)
        if let cache, let key { cache.store(result, key: key) }
        return result
    }

    /// WebM analyses wait for each other (frames come one lane job at a time, see `measure`).
    private static let webMTurn = AnalysisTurn()

    private func measure(sourceRange: TimeRange, pictureWidth: Int, pictureHeight: Int,
                         progress: (@Sendable (Double) -> Void)?) async throws -> StabilizationAnalysis {
        func cm(_ t: Time) -> CMTime { CMTime(value: t.value, timescale: CMTimeScale(clamping: t.timescale)) }
        let pass = Pass(maxDimension: maxDimension, minFrameInterval: minFrameInterval,
                        pictureWidth: pictureWidth, pictureHeight: pictureHeight,
                        start: cm(sourceRange.start).seconds,
                        total: max(Double(sourceRange.duration.value) / Double(sourceRange.duration.timescale), 1e-6),
                        progress: progress)

        if WebMFile.isWebM(url) {   // AVAssetReader cannot open WebM: frames come from the WebM decoder (always upright)
            // The decoder hands out frames on its own path; shrinking and registering one (Vision is synchronous) blocks,
            // so each frame's share runs on the analysis lane like the read loop below, never on the cooperative pool.
            // One WebM analysis at a time (`AnalysisTurn`): their per-frame lane jobs would alternate on a 1-wide lane.
            return try await Self.webMTurn.run {
                try await WebMReadback.forEachFrame(url: url, range: sourceRange) { frame in
                    try Task.checkCancellation()
                    nonisolated(unsafe) let pb = frame.pixelBuffer
                    let pts = cm(frame.pts)
                    try await BlockingLane.analysis.run { _ in pass.add(pb, pts: pts, orientation: .up) }
                }
                try Task.checkCancellation()
                return pass.finish()
            }
        }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StabilizationError.noVideoTrack }
        let preferred = try await track.load(.preferredTransform)
        let quarter = Int((atan2(Double(preferred.b), Double(preferred.a)) * 2 / .pi).rounded())
        let orientation = PersonSegmenter.orientation(quarterTurns: quarter)
        pass.quarterTurns = ((quarter % 4) + 4) % 4
        // The decoder scales to the analysis size (`decodeSize`): a 4K frame is never made as full-size BGRA. Full-size
        // BGRA of the Sony 4K clip took VTDecoderXPCService from 5 to 24 GB footprint (full-size 4:2:0: 12 GB; scaled:
        // +0.6 GB) at the same or better speed (EngineBench stabilize, 2026-10-04). Interlaced media is the exception:
        // its fields need the stored lines, so it is decoded at full size, deinterlaced, then shrunk (`AnalysisFields`).
        let size = Self.decodeSize(natural: try await track.load(.naturalSize), maxDimension: maxDimension)
        let fields = deinterlace
        pass.deinterlace = fields
        let timeRange = CMTimeRange(start: cm(sourceRange.start), duration: cm(sourceRange.duration))
        nonisolated(unsafe) let videoTrack = track   // its properties are loaded; the lane body only hands it to the output

        // The read + registration loop blocks (decode waits, Vision is synchronous): it runs on the analysis lane, never
        // on the cooperative pool, and the lane is 1 wide on small/8 GB Macs (`WorkLimits.pictureAnalyzes`).
        return try await BlockingLane.analysis.run { isCancelled in
            let (reader, output) = try AnalysisFields.start(asset: asset, track: videoTrack, order: fields, size: size,
                                                            timeRange: timeRange)
            defer { if reader.status == .reading { reader.cancelReading() } }

            while let sample = output.copyNextSampleBuffer() {
                if isCancelled() { throw CancellationError() }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                pass.add(pb, pts: CMSampleBufferGetPresentationTimeStamp(sample), orientation: orientation)
            }
            if isCancelled() { throw CancellationError() }
            if reader.status == .failed { throw reader.error ?? StabilizationError.unreadable }
            return pass.finish()
        }
    }

    /// One analysis pass: shrink each frame, register it against the previous one (Vision, plus the photometric check
    /// for confidence, the guard and cut scores), record. Used by one thread at a time (the lane body; WebM: one lane
    /// job per frame, one after the other), hence unchecked.
    final class Pass: @unchecked Sendable {
        let maxDimension: Int, minFrameInterval: Double, pictureWidth: Int, pictureHeight: Int, start: Double, total: Double
        let progress: (@Sendable (Double) -> Void)?
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var times: [Time] = [], motions: [CameraMotion] = [], cuts: [Int] = []
        /// The residual perspective of each pair (picture px), in step with `motions`; zero where there is none.
        var perspective: [PerspectiveResidual] = []
        var confidence: [Double] = [], checks: [CameraMotion?] = [], histogramJumps: [Double] = [], residuals: [Double] = []
        var previous: CVPixelBuffer?
        var previousGray: GrayFrame?, previousHistogram: [Float]?
        /// The feature tracker's pyramid of the previous frame (FeatureTracker.swift).
        var previousPyramid: FeaturePyramid?
        var factor = 1.0
        var factorY = 1.0
        /// Rolling shutter (RollingShutterMeasure): the per-pair samples and how the sensor rows lie in the upright picture.
        var rolling: [RollingShutterSample?] = []
        var quarterTurns = 0
        /// The time of the last frame received and the gaps between all of them, skipped ones included: the source's
        /// own frame interval (`StabilizationAnalysis.sourceFrameInterval`).
        var lastSeen: Double?
        var gaps: [Double] = []
        /// Field order of interlaced media: every frame that is registered is deinterlaced first (skipped ones are not).
        var deinterlace: FieldOrder?

        init(maxDimension: Int, minFrameInterval: Double = 0, pictureWidth: Int, pictureHeight: Int, start: Double, total: Double,
             progress: (@Sendable (Double) -> Void)?) {
            self.maxDimension = maxDimension; self.minFrameInterval = minFrameInterval
            self.pictureWidth = pictureWidth; self.pictureHeight = pictureHeight
            self.start = start; self.total = total; self.progress = progress
        }

        func add(_ pb: CVPixelBuffer, pts: CMTime, orientation: CGImagePropertyOrientation) {
            guard pts.isNumeric, pts.timescale > 0 else { return }
            if let seen = lastSeen, pts.seconds > seen { gaps.append(pts.seconds - seen) }
            lastSeen = max(lastSeen ?? pts.seconds, pts.seconds)
            if let last = times.last {
                let gap = pts.seconds - Double(last.value) / Double(last.timescale)
                guard gap > 0, gap >= minFrameInterval else { return }   // a zero gap (duplicate pts) never makes a pair
            }
            guard let small = VisionStabilizationAnalyzer.shrink(AnalysisFields.progressive(pb, deinterlace), orientation: orientation,
                                                                 maxDimension: maxDimension, context: context) else { return }
            if previous == nil, CVPixelBufferGetWidth(small) > 0 {
                factor = Double(pictureWidth) / Double(CVPixelBufferGetWidth(small))
                factorY = Double(pictureHeight) / Double(max(CVPixelBufferGetHeight(small), 1))
            }
            let gray = GrayFrame(halving: small)
            let histogram = gray?.quadrantHistograms()
            let pyramid = GrayFrame(fullSize: small).flatMap { FeaturePyramid($0) }
            var motion: CameraMotion?
            var featureConfidence: Double?
            var residual = PerspectiveResidual.zero
            if let p = previous {
                // Tracked features first (robust to moving subjects); Vision's registration only for frames the tracker
                // calls weak (blur, a blank wall, a cut), so the fallback keeps its old cut handling.
                if let pp = previousPyramid, let cp = pyramid, let fm = FeatureTracker.register(previous: pp, current: cp) {
                    motion = Registration.scaled(fm.motion, x: factor, y: factorY)
                    featureConfidence = fm.confidence
                    residual = fm.residual?.scaled(x: factor, y: factorY) ?? .zero
                } else if let m = Registration.matched(previous: p, current: small) { motion = Registration.scaled(m, x: factor, y: factorY) }
                else { cuts.append(motions.count) }     // no match with the previous frame: the camera path restarts here
                let check = previousGray.flatMap { pg in gray.flatMap { PhotometricRegistration.register(previous: pg, current: $0) } }
                let checkFactor = Double(pictureWidth) / Double(max(gray?.width ?? 1, 1))
                // The picture size is the displayed one: with non-square pixels (anamorphic) a stored pixel is wider
                // than tall, so the vertical factor is its own.
                let checkFactorY = Double(pictureHeight) / Double(max(gray?.height ?? 1, 1))
                let usable = check.flatMap { $0.converged && $0.texture >= PhotometricRegistration.minTexture ? $0 : nil }
                let inSource = usable.map { Registration.scaled($0.motion, x: checkFactor, y: checkFactorY) }
                checks.append(inSource)
                // Always measured (about as much work as the check's own cells): switching Rolling Shutter on later
                // then needs no second analysis.
                rolling.append(usable.flatMap { u in
                    guard let pg = previousGray, let g = gray else { return nil }
                    return RollingShutterMeasure.sample(previous: pg, current: g, around: u.motion, alongX: quarterTurns % 2 != 0,
                                                        factorX: checkFactor, factorY: checkFactorY)
                })
                confidence.append(featureConfidence ?? motion.map {
                    PhotometricRegistration.confidence(vision: $0, check: usable, checkInSource: inSource,
                                                       pictureWidth: pictureWidth, pictureHeight: pictureHeight)
                } ?? 0)
                residuals.append(check?.residual ?? .nan)
                histogramJumps.append(previousHistogram.flatMap { ph in histogram.map { GrayFrame.histogramDistance(ph, $0) } } ?? .nan)
            } else {
                checks.append(nil); confidence.append(1); residuals.append(0); histogramJumps.append(0); rolling.append(nil)
            }
            motions.append(motion ?? .identity)
            perspective.append(residual)
            times.append(Time(pts.value, Int64(pts.timescale)))
            previous = small
            previousGray = gray; previousHistogram = histogram; previousPyramid = pyramid
            progress?(min(max((pts.seconds - start) / total, 0), 1))
        }

        func finish() -> StabilizationAnalysis {
            progress?(1)
            // Cuts: "no match" plus the change scores (a registration also "matches" across many cuts).
            let detected = StabilizationCuts.detect(motions: motions, histogram: histogramJumps, residual: residuals,
                                                    checks: checks, confidence: confidence)
            return StabilizationAnalysis(pictureWidth: pictureWidth, pictureHeight: pictureHeight, frameTimes: times,
                                         motions: motions, cuts: Set(cuts + detected).sorted(), confidence: confidence,
                                         checks: checks, rolling: rolling, rollingScan: quarterTurns,
                                         sourceFrameInterval: gaps.isEmpty ? 0 : gaps.sorted()[gaps.count / 2],
                                         perspective: perspective.contains { !$0.isZero } ? perspective : [])
        }
    }

    /// The size the decoder should deliver frames at (stored orientation): long side `maxDimension`, even sides, aspect
    /// kept; nil when the frames are no larger (or have no size).
    static func decodeSize(natural: CGSize, maxDimension: Int) -> (width: Int, height: Int)? {
        let w = abs(Double(natural.width)), h = abs(Double(natural.height)), long = max(w, h)
        guard long > Double(maxDimension), min(w, h) > 0, maxDimension > 0 else { return nil }
        let s = Double(maxDimension) / long
        func even(_ v: Double) -> Int { max(2, Int((v * s / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    /// Size of the shrunk analysis frame of a decoded frame `width` x `height` (stored pixels of shape `pixelAspect`,
    /// before `quarterTurned` puts it upright): the picture as it is shown (`width * pixelAspect` wide), long side at
    /// most `maxDimension`, never enlarged. nil for an empty frame.
    static func shrunkSize(width: Int, height: Int, pixelAspect: PixelAspect = .square, quarterTurned: Bool = false,
                           maxDimension: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, maxDimension > 0 else { return nil }
        let shownW = Double(width) * pixelAspect.value, shownH = Double(height)
        // Squeezed pixels are widened only as far as the stored picture has detail: never above the stored long side.
        let s = min(1, Double(maxDimension) / max(shownW, shownH), Double(max(width, height)) / max(shownW, shownH))
        let w = max(Int((shownW * s).rounded()), 1), h = max(Int((shownH * s).rounded()), 1)
        return quarterTurned ? (h, w) : (w, h)
    }

    /// The frame as the monitor shows it, with its long side at most `maxDimension`, as a BGRA buffer Vision reads:
    /// the whole decoded buffer (the app draws it whole, a clean aperture tag crops nothing: a matte made on a cropped
    /// picture would sit shifted on the clip), pixels of shape `pixelAspect` made square (Vision knows people as they
    /// look, not squeezed by an anamorphic lens), then upright.
    static func shrink(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation, maxDimension: Int,
                       pixelAspect: PixelAspect = .square, context: CIContext) -> CVPixelBuffer? {
        let stored = CIImage(cvPixelBuffer: pb, options: [.applyCleanAperture: false])
        let turned = [CGImagePropertyOrientation.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        guard let (w, h) = shrunkSize(width: Int(stored.extent.width), height: Int(stored.extent.height), pixelAspect: pixelAspect,
                                      quarterTurned: turned, maxDimension: maxDimension) else { return nil }
        var image = stored.oriented(orientation)
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: Double(w) / Double(e.width), y: Double(h) / Double(e.height)))
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs, &out) == kCVReturnSuccess, let out else { return nil }
        context.render(image, to: out)
        return out
    }
}

// MARK: - Cache

/// Analysis results as JSON files: `<caches>/Sequence Studio/Stabilizer/<key>.json`. The key covers the file (path, size,
/// modification date), the source range, the analysis size and `StabilizationAnalysis.currentVersion`, so an edited or
/// replaced file, another range or a newer analysis is measured again.
/// Files of older analysis versions are deleted on the first store of a launch; the folder is capped at `limitBytes`
/// (least recently used first) and nothing is written below the shared free-space floor (`CacheDiskPolicy`).
public final class StabilizationCache: Sendable {
    public let root: URL
    public let limitBytes: Int
    private let disk: CacheDiskPolicy
    private let swept = Mutex(false)

    /// `cachesDirectory` nil: the app's analysis cache (`AnalysisCacheLocation`, `<cache folder>/Stabilizer`).
    public init(cachesDirectory: URL? = nil, limitBytes: Int = 200 << 20, disk: CacheDiskPolicy = .standard) {
        root = cachesDirectory.map { $0.appendingPathComponent("Sequence Studio", isDirectory: true)
            .appendingPathComponent("Stabilizer", isDirectory: true) } ?? AnalysisCacheLocation.sharedDirectory("Stabilizer")
        self.limitBytes = limitBytes
        self.disk = disk
    }

    /// nil when the file cannot be read.
    /// `deinterlace`: the analyzer's field order; the key of progressive media (nil) is the one it always had, so a
    /// changed Deinterlace switch measures again and nothing else does.
    public func key(url: URL, range: TimeRange, maxDimension: Int, deinterlace: FieldOrder? = nil) -> String? {
        // A fresh URL: `URL` caches resource values, and a file rewritten in place must miss.
        guard let v = FileWalk.Values.read(URL(fileURLWithPath: url.path), keys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let date = v.contentModificationDate else { return nil }
        let text = [url.standardizedFileURL.path, "\(size)", "\(date.timeIntervalSinceReferenceDate)",
                    "\(range.start.value)/\(range.start.timescale)", "\(range.duration.value)/\(range.duration.timescale)",
                    "\(maxDimension)", "v\(StabilizationAnalysis.currentVersion)"].joined(separator: "|")
            + (deinterlace.map { "|deinterlaced-\($0.rawValue)" } ?? "")
        return Self.hash(text)
    }

    /// FNV-1a 64 of the UTF-8 bytes as 16 hex digits (stable across launches, unlike `hashValue`).
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    func file(_ key: String) -> URL { root.appendingPathComponent("\(key).json") }

    public func load(key: String) -> StabilizationAnalysis? {
        guard let data = try? Data(contentsOf: file(key)),
              let a = try? JSONDecoder().decode(StabilizationAnalysis.self, from: data),
              a.version == StabilizationAnalysis.currentVersion, a.frameTimes.count == a.motions.count else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file(key).path)     // last use
        return a
    }

    /// The cached analysis for a file and range (as `VisionStabilizationAnalyzer` stored it); nil when there is none.
    public func cached(url: URL, range: TimeRange, pictureWidth: Int, pictureHeight: Int, maxDimension: Int = VisionStabilizationAnalyzer.defaultMaxDimension) -> StabilizationAnalysis? {
        guard let key = key(url: url, range: range, maxDimension: maxDimension), let hit = load(key: key),
              hit.pictureWidth == pictureWidth, hit.pictureHeight == pictureHeight else { return nil }
        return hit
    }

    public func store(_ a: StabilizationAnalysis, key: String) {
        guard let data = try? JSONEncoder().encode(a) else { return }
        // Low disk: skip the write (the analysis reruns on demand) and free what the cache holds.
        guard disk.allowsWrite(bytes: Int64(data.count), at: root) else { prune(limit: 0); return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if swept.withLock({ let first = !$0; $0 = true; return first }) { removeOtherVersions() }
        try? data.write(to: file(key), options: .atomic)
        prune(limit: limitBytes)
    }

    /// Deletes files whose analysis version is not the current one (their keys can never match again).
    func removeOtherVersions() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for u in files where u.pathExtension == "json" {
            guard let data = try? Data(contentsOf: u),
                  let v = try? JSONDecoder().decode(VersionOnly.self, from: data), v.version == StabilizationAnalysis.currentVersion
            else { try? FileManager.default.removeItem(at: u); continue }
        }
    }
    private struct VersionOnly: Decodable { var version: Int }

    /// Deletes the least recently used files until the folder fits `limit` bytes.
    func prune(limit: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
        let entries = files.filter { $0.pathExtension == "json" }.compactMap { u -> CacheEntry? in
            guard let v = FileWalk.Values.read(u, keys: Set(keys)) else { return nil }
            return CacheEntry(id: u.lastPathComponent, bytes: Int64(v.fileSize ?? 0), lastUse: v.contentModificationDate ?? .distantPast)
        }
        for id in CacheDiskPolicy.evictionPlan(entries, limitBytes: Int64(limit), protecting: []) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
        }
    }
}

// MARK: - QA hooks

/// The analysis' own shrink and registration, for measuring the result on real footage (EngineBench `stabilize`
/// re-registers the corrected frames to measure the residual shake).
// shortcut: synchronous, no lane: only EngineBench and tests call these, on their own thread; the app's analysis goes through
// `VisionStabilizationAnalyzer.analyze` (lane). Upgrade when an app path needs a single registration.
public enum StabilizationProbe {
    /// The frame upright with its long side at most `maxDimension` (what Vision sees).
    public static func smallFrame(_ pb: CVPixelBuffer, orientation: CGImagePropertyOrientation, maxDimension: Int,
                                  context: CIContext) -> CVPixelBuffer? {
        VisionStabilizationAnalyzer.shrink(pb, orientation: orientation, maxDimension: maxDimension, context: context)
    }

    /// Content motion previous -> current in px of the given buffers; nil when they do not match (a cut).
    public static func motion(previous: CVPixelBuffer, current: CVPixelBuffer) -> CameraMotion? {
        Registration.matched(previous: previous, current: current)
    }

    /// The two registrations on their own (homography reduced to a similarity; translation only).
    /// Trusted homographies only (`Registration.homographyTrusted`); nil otherwise.
    public static func homography(previous: CVPixelBuffer, current: CVPixelBuffer) -> CameraMotion? {
        guard let h = Registration.homography(previous: previous, current: current),
              Registration.homographyTrusted(rest: h.rest, width: CVPixelBufferGetWidth(current),
                                             height: CVPixelBufferGetHeight(current)) else { return nil }
        return h.motion
    }
    /// Homography motion plus its non-similarity rest (px), trusted or not.
    public static func homographyRest(previous: CVPixelBuffer, current: CVPixelBuffer) -> (CameraMotion, Double)? {
        Registration.homography(previous: previous, current: current).map { ($0.motion, $0.rest) }
    }
    public static func translation(previous: CVPixelBuffer, current: CVPixelBuffer) -> CameraMotion? {
        Registration.translationalMotion(previous: previous, current: current)
    }

    /// The photometric check of a pair as the analysis runs it (small frames from `smallFrame`): its motion in px of the
    /// given buffers, residual, texture, converged; plus the histogram jump. For calibrating the thresholds.
    public static func check(previous: CVPixelBuffer, current: CVPixelBuffer)
        -> (motion: CameraMotion, residual: Double, texture: Double, converged: Bool, histogram: Double)? {
        guard let a = GrayFrame(halving: previous), let b = GrayFrame(halving: current),
              let r = PhotometricRegistration.register(previous: a, current: b) else { return nil }
        let f = Double(CVPixelBufferGetWidth(current)) / Double(b.width)
        return (Registration.scaled(r.motion, by: f), r.residual, r.texture, r.converged,
                GrayFrame.histogramDistance(a.quadrantHistograms(), b.quadrantHistograms()))
    }
}
