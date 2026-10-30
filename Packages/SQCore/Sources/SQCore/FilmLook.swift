import Foundation

/// The "film / tape look" of a clip at one instant: Film Grain, Halation, Bloom, Gate Weave, Scanlines, Chroma Bleed and
/// Tracking Noise, already evaluated and clamped (sibling of `ChromaKey` and friends inside `ClipEffects`).
///
/// All sizes are px of a 1080-line frame; the renderer scales them with the layer's height, so a 4K clip looks like its 1080p
/// version. A nil member is identity. The look runs as one extra pass after every other effect of the clip (Crop, Rounded
/// Corners, Blur, Ultra Key), before the layer is transformed and composited; the order inside the pass is fixed: tracking
/// noise, chroma bleed, grain, scanlines. Gate Weave is not part of the pass: it moves the layer.
public struct FilmLook: Sendable, Hashable {
    public struct Grain: Sendable, Hashable {
        /// 0...1 strength of the noise.
        public var amount: Double
        /// Grain size in px (a grain covers about size x size).
        public var size: Double
        /// 0...1 how much the noise is smoothed (pre-blur).
        public var softness: Double
        /// 0...1: 0 = same grain everywhere, 1 = only in the mid-tones (fades out in deep shadows and highlights).
        public var lumaWeight: Double
        /// 0...1: 0 = one gray noise for all channels, 1 = independent noise per color channel.
        public var color: Double
        /// Noise pattern id: changes 24 times a second when the grain is animated, constant otherwise.
        public var seed: UInt32
        public init(amount: Double, size: Double, softness: Double, lumaWeight: Double, color: Double = 0, seed: UInt32) {
            self.amount = amount; self.size = size; self.softness = softness; self.lumaWeight = lumaWeight; self.color = color
            self.seed = seed
        }
    }
    public struct Scanlines: Sendable, Hashable {
        /// 0...1 how dark the gaps are.
        public var intensity: Double
        /// Distance between two lines in px.
        public var spacing: Double
        /// 0...1 share of the spacing that is dark.
        public var thickness: Double
        public init(intensity: Double, spacing: Double, thickness: Double) {
            self.intensity = intensity; self.spacing = spacing; self.thickness = thickness
        }
    }
    public struct ChromaBleed: Sendable, Hashable {
        /// Horizontal smear of the color in px.
        public var bleed: Double
        /// Horizontal offset of the color against the brightness in px (tape lag).
        public var shift: Double
        public init(bleed: Double, shift: Double) { self.bleed = bleed; self.shift = shift }
    }
    public struct Tracking: Sendable, Hashable {
        /// 0...1 strength of the line wobble and the noise streaks.
        public var amount: Double
        /// 0...1 height of the disturbed band as a share of the frame.
        public var bandHeight: Double
        /// 0...1 position of the band (0 = bottom edge, 1 = top edge); rolls with time.
        public var phase: Double
        public var seed: UInt32
        public init(amount: Double, bandHeight: Double, phase: Double, seed: UInt32) {
            self.amount = amount; self.bandHeight = bandHeight; self.phase = phase; self.seed = seed
        }
    }

    /// Aged Film: dust, scratches and flicker of worn film, all per frame (1/24 s steps) and deterministic from the seed.
    public struct Aged: Sendable, Hashable {
        /// 0...1 how many specks of dust show on a frame.
        public var dust: Double
        /// 0...1 how many vertical scratches show (up to 3 at 100 %).
        public var scratches: Double
        /// 0...1 strength of the frame-to-frame exposure flutter.
        public var flicker: Double
        /// Frame id: the dust and the flicker change every 1/24 s, the scratches stay for 3 steps.
        public var seed: UInt32
        public init(dust: Double, scratches: Double, flicker: Double, seed: UInt32) {
            self.dust = dust; self.scratches = scratches; self.flicker = flicker; self.seed = seed
        }
    }

    public var grain: Grain?
    public var aged: Aged?
    public var scanlines: Scanlines?
    public var chromaBleed: ChromaBleed?
    public var tracking: Tracking?
    public var weave: GateWeave?

    public init(grain: Grain? = nil, scanlines: Scanlines? = nil,
                chromaBleed: ChromaBleed? = nil, tracking: Tracking? = nil, weave: GateWeave? = nil, aged: Aged? = nil) {
        self.grain = grain; self.aged = aged; self.scanlines = scanlines
        self.chromaBleed = chromaBleed; self.tracking = tracking; self.weave = weave
    }

    public static let none = FilmLook()
    /// Nothing to do at all (no pass, no weave).
    public var isIdentity: Bool { !needsPass && weave == nil }
    /// The renderer must run the look pass (everything but Gate Weave, which only moves the layer).
    public var needsPass: Bool {
        grain != nil || aged != nil || scanlines != nil || chromaBleed != nil || tracking != nil
    }

    /// Grain steps per second: grain animates at the film frame rate, whatever the timeline rate is.
    public static let grainRate: Int64 = 24
    /// Noise pattern id at `local` (clip-local time): one step per 1/24 s.
    static func seed(atLocal local: Time) -> UInt32 {
        let n = max(0, local.value * grainRate / max(1, local.timescale))
        return UInt32(truncatingIfNeeded: n)
    }
}

/// Gate Weave: the picture drifts a little in the projector gate, a slow wander plus a per-frame tremble. The layer is
/// moved by `offsetX`/`offsetY` (px of a 1080-line frame) and turned by `rotation` degrees, and scaled up just enough that
/// the weave never shows the edge of the picture.
public struct GateWeave: Sendable, Hashable {
    public var offsetX: Double, offsetY: Double
    public var rotation: Double
    /// The most the offset can reach (the Amount setting) and the largest rotation, for the overscan.
    public var maxOffset: Double, maxRotation: Double
    public init(offsetX: Double, offsetY: Double, rotation: Double, maxOffset: Double, maxRotation: Double) {
        self.offsetX = offsetX; self.offsetY = offsetY; self.rotation = rotation
        self.maxOffset = maxOffset; self.maxRotation = maxRotation
    }

    /// Scale (>= 1) that keeps a `width` x `height` frame covering its own rectangle at the worst weave. `scale` converts
    /// 1080-line px to the frame's px.
    public func overscan(width: Double, height: Double, scale: Double) -> Double {
        let off = maxOffset * scale
        let rot = maxRotation * .pi / 180
        let halfDiag = 0.5 * (width * width + height * height).squareRoot()
        let grow = 2 * off + 2 * halfDiag * sin(rot)
        return 1 + grow / max(1, min(width, height))
    }

    /// Hash of an integer to 0...1 (deterministic, no state).
    static func hash(_ n: Int64, _ salt: UInt64) -> Double {
        var x = UInt64(bitPattern: n) &+ salt &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 30; x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27; x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return Double(x >> 11) / Double(1 << 53)
    }
    /// Smooth value noise in -1...1 at `t` (cosine-interpolated lattice values).
    static func noise(_ t: Double, _ salt: UInt64) -> Double {
        let i = Int64(t.rounded(.down)), f = t - Double(i)
        let u = (1 - cos(f * .pi)) / 2
        let a = hash(i, salt) * 2 - 1, b = hash(i + 1, salt) * 2 - 1
        return a + (b - a) * u
    }

    /// The weave at clip-local `seconds`: a wander at `speed` Hz plus a tremble that changes every 1/24 s.
    public static func evaluate(amount: Double, speed: Double, rotation: Double, atLocalSeconds s: Double) -> GateWeave {
        let step = (s * Double(FilmLook.grainRate)).rounded(.down)
        func axis(_ salt: UInt64) -> Double {
            let wander = noise(s * speed, salt)
            let tremble = (hash(Int64(step), salt &+ 77) * 2 - 1) * 0.25
            return max(-1, min(1, wander * 0.8 + tremble))
        }
        return GateWeave(offsetX: amount * axis(1), offsetY: amount * 0.7 * axis(2), rotation: rotation * axis(3),
                         maxOffset: amount, maxRotation: rotation)
    }
}
