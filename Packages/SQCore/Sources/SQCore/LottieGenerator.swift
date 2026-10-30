import Foundation

// Lottie generator clips: a user-supplied Lottie JSON (bodymovin) drawn as a picture layer next to text and shapes. The file is
// embedded in the clip's payload (project stays portable, nothing is bundled from third parties); the rasterizer lives in
// SQLottie (ThorVG). This file holds only the pure logic: header parsing, limits, timing (frame at a clip time), raster size.
// The kind string is stored: never rename.

extension GeneratorRef {
    public static let lottie = "lottie"
    /// A Lottie clip: payload is a JSON `LottieSpec`.
    public static func lottie(_ spec: LottieSpec) -> GeneratorRef {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return GeneratorRef(kind: lottie, payload: (try? e.encode(spec)) ?? Data())
    }
    /// The decoded spec; nil for another kind or an undecodable payload.
    public var lottieSpec: LottieSpec? {
        kind == GeneratorRef.lottie ? try? JSONDecoder().decode(LottieSpec.self, from: payload) : nil
    }
}

public enum LottieLimits {
    /// Largest Lottie file accepted (it is stored inside the project).
    public static let maxBytes = 8 << 20
    /// Longest side in px, for the animation's own size and for the raster.
    public static let maxSide = 4096
}

/// What a Lottie clip holds: the file's bytes and the play settings.
public struct LottieSpec: Sendable, Hashable, Codable {
    public var json: Data
    /// File name the user picked (shown, never read back from disk).
    public var sourceName: String
    /// Repeat from the start when the clip is longer than the animation; false holds the last frame.
    public var loops: Bool
    public var speed: Double
    public init(json: Data, sourceName: String, loops: Bool = true, speed: Double = 1) {
        self.json = json; self.sourceName = sourceName; self.loops = loops; self.speed = speed
    }
}

/// The header of a Lottie document.
public struct LottieInfo: Sendable, Hashable {
    public var width: Int, height: Int
    public var frameRate: Double
    public var inPoint: Double, outPoint: Double
    public var name: String?

    public var frameCount: Double { outPoint - inPoint }
    /// One play of the animation, exact (frames / rate in thousandths).
    public var duration: Time { Time(Int64((frameCount * 1000).rounded()), Int64((frameRate * 1000).rounded())) }

    /// Reads the header; nil when `json` is not a usable Lottie document (not JSON, no layers, bad size, rate or range,
    /// or over the size limits).
    public static func parse(_ json: Data) -> LottieInfo? {
        guard json.count <= LottieLimits.maxBytes, !json.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              root["layers"] is [Any],
              let w = (root["w"] as? NSNumber)?.intValue, let h = (root["h"] as? NSNumber)?.intValue,
              let fr = (root["fr"] as? NSNumber)?.doubleValue,
              let ip = (root["ip"] as? NSNumber)?.doubleValue, let op = (root["op"] as? NSNumber)?.doubleValue,
              w > 0, h > 0, w <= LottieLimits.maxSide, h <= LottieLimits.maxSide,
              fr.isFinite, fr > 0, fr <= 1000, ip.isFinite, op.isFinite, op > ip, op - ip <= 1_000_000
        else { return nil }
        return LottieInfo(width: w, height: h, frameRate: fr, inPoint: ip, outPoint: op, name: root["nm"] as? String)
    }
}

public enum LottieTiming {
    /// The animation frame shown at `localTime` (seconds from the clip start): `inPoint` + time x rate x speed, wrapped
    /// when looping, else held on the last frame (`outPoint - 1`).
    public static func frame(localTime: Time, info: LottieInfo, spec: LottieSpec) -> Double {
        let t = max(0, Double(localTime.value) / Double(localTime.timescale))
        let advanced = t * info.frameRate * (spec.speed.isFinite ? max(0, spec.speed) : 1)
        let span = info.frameCount
        let local: Double
        if spec.loops {
            local = advanced.truncatingRemainder(dividingBy: span)
        } else {
            local = min(advanced, max(span - 1, 0))
        }
        return info.inPoint + local
    }

    /// Raster size in px: the animation scaled to fit the canvas (aspect kept, up or down), at most `maxSide` per side, so a
    /// small sticker stays sharp at full size. Both sides are at least 1.
    public static func rasterSize(info: LottieInfo, canvasWidth: Int, canvasHeight: Int) -> (width: Int, height: Int) {
        let cw = Double(max(canvasWidth, 1)), ch = Double(max(canvasHeight, 1))
        var k = min(cw / Double(info.width), ch / Double(info.height))
        k = min(k, Double(LottieLimits.maxSide) / Double(max(info.width, info.height)))
        let w = min(max(Int((Double(info.width) * k).rounded()), 1), LottieLimits.maxSide)
        let h = min(max(Int((Double(info.height) * k).rounded()), 1), LottieLimits.maxSide)
        return (w, h)
    }
}

public enum LottieImportError: Error, Equatable, LocalizedError {
    /// Not a Lottie document, or over the size limits.
    case invalid
    public var errorDescription: String? {
        "This is not a Lottie animation Sequence Studio can use. It needs to be a Lottie .json file of at most 8 MB and 4096 px."
    }
}

extension Project {
    /// Places a Lottie clip of the animation's own length (rounded up to whole frames) on a video track. Throws
    /// `LottieImportError.invalid` for unusable JSON, else what `addGeneratorClip` throws.
    @discardableResult
    public mutating func addLottieClip(json: Data, name: String, in timeline: Timeline.ID, at start: Time, track: Track.ID,
                                       loops: Bool = true) throws -> Clip.ID {
        guard let info = LottieInfo.parse(json) else { throw LottieImportError.invalid }
        guard let tl = timelines.first(where: { $0.id == timeline }) else { throw EditError.timelineNotFound }
        let spec = LottieSpec(json: json, sourceName: name, loops: loops)
        let ref = GeneratorRef.lottie(spec)
        let base = NSString(string: name).deletingPathExtension
        return try addGeneratorClip(kind: ref.kind, payload: ref.payload, payloadVersion: ref.payloadVersion,
                                    name: base.isEmpty ? "Lottie" : base, in: timeline, at: start, track: track,
                                    duration: info.duration.ceiled(to: tl.frameDuration))
    }
}
