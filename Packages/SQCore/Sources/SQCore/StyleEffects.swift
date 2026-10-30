import Foundation

// FB-T2 style effects: Premiere's names, defaults and ranges where Premiere has the effect (Radial Blur, Horizontal /
// Vertical Flip, Invert, Posterize, Tint, Black & White, Brightness & Contrast, Twirl, Wave Warp, Spherize, Strobe Light,
// Alpha Adjust), and visible start values for the short-form looks Premiere only has inside Lumetri or not at all
// (Vignette, Film Grain, RGB Split). Each evaluates into one `ImageFilter` (W3.1 pipeline); every parameter is keyframable.
// Stored kind and key strings: never rename.

extension ClipEffect {
    public static let vignetteKind = "vignette", vignetteAmountKey = "vignetteAmount", vignetteMidpointKey = "vignetteMidpoint"
    public static let vignetteRoundnessKey = "vignetteRoundness", vignetteFeatherKey = "vignetteFeather"
    public static let grainKind = "filmGrain", grainAmountKey = "grainAmount", grainSizeKey = "grainSize"
    public static let grainColorKey = "grainColor", grainResponseKey = "grainResponse"
    public static let grainSoftnessKey = "grainSoftness", grainAnimateKey = "grainAnimate"
    public static let rgbSplitKind = "rgbSplit", rgbSplitAmountKey = "splitAmount", rgbSplitAngleKey = "splitAngle"
    public static let rgbSplitModeKey = "splitMode", rgbSplitBlendKey = "splitBlend"
    public static let radialBlurKind = "radialBlur", radialAmountKey = "radialAmount", radialCenterKey = "radialCenter"
    public static let radialTypeKey = "radialType", radialQualityKey = "radialQuality"
    public static let horizontalFlipKind = "horizontalFlip", verticalFlipKind = "verticalFlip"
    public static let invertKind = "invert", invertChannelKey = "invertChannel", invertBlendKey = "invertBlend"
    public static let posterizeKind = "posterize", posterizeLevelKey = "posterizeLevel"
    public static let tintKind = "tint", tintBlackKey = "mapBlackTo", tintWhiteKey = "mapWhiteTo", tintAmountKey = "amountToTint"
    public static let blackAndWhiteKind = "blackAndWhite"
    public static let brightnessContrastKind = "brightnessContrast", brightnessKey = "brightness", contrastKey = "contrast"
    public static let twirlKind = "twirl", twirlAngleKey = "twirlAngle", twirlRadiusKey = "twirlRadius", twirlCenterKey = "twirlCenter"
    /// Corner Warp: each corner of the picture moved by its own offset (px, points; zero = in place).
    public static let cornerPinKind = "cornerPin", cornerPinTopLeftKey = "cornerPinTopLeft", cornerPinTopRightKey = "cornerPinTopRight"
    public static let cornerPinBottomRightKey = "cornerPinBottomRight", cornerPinBottomLeftKey = "cornerPinBottomLeft"
    public static let waveWarpKind = "waveWarp", waveTypeKey = "waveType", waveHeightKey = "waveHeight", waveWidthKey = "waveWidth"
    public static let waveDirectionKey = "waveDirection", waveSpeedKey = "waveSpeed", wavePinningKey = "wavePinning"
    public static let wavePhaseKey = "wavePhase"
    public static let spherizeKind = "spherize", spherizeRadiusKey = "spherizeRadius", spherizeCenterKey = "spherizeCenter"
    public static let spherizeStrengthKey = "spherizeStrength"
    public static let strobeKind = "strobeLight", strobeColorKey = "strobeColor", strobeBlendKey = "strobeBlend"
    public static let strobeDurationKey = "strobeDuration", strobePeriodKey = "strobePeriod", strobeRandomKey = "strobeRandom"
    public static let strobeModeKey = "strobeMode", strobeOperatorKey = "strobeOperator"
    public static let alphaAdjustKind = "alphaAdjust", alphaOpacityKey = "alphaOpacity", alphaIgnoreKey = "ignoreAlpha"
    public static let alphaInvertKey = "invertAlpha", alphaMaskOnlyKey = "maskOnly"
    public static let lensDistortionKind = "lensDistortion", lensCurvatureKey = "curvature"
    public static let lensVDecenterKey = "verticalDecentering", lensHDecenterKey = "horizontalDecentering"
    public static let lensFillAlphaKey = "fillAlpha", lensFillColorKey = "fillColor", lensAutoScaleKey = "autoScale"
    /// 1 = the exact lens model (positive Curvature undoes the negative one, cubic resampling). Written on every new Lens
    /// Distortion; an effect saved before F7.15 has no such key and keeps its look. Auto Scale always uses the exact
    /// model. No Effect Controls row. Never rename.
    public static let lensModelKey = "lensModel"
    public static let lightLeakKind = "lightLeak", leakColor1Key = "leakColor1", leakColor2Key = "leakColor2"
    public static let leakIntensityKey = "leakIntensity", leakAngleKey = "leakAngle", leakSizeKey = "leakSize"
    public static let leakSpeedKey = "leakSpeed", leakSeedKey = "leakSeed"
    public static let gradientKind = "gradient", gradientColor1Key = "gradientColor1", gradientColor2Key = "gradientColor2"
    public static let gradientStartKey = "gradientStart", gradientEndKey = "gradientEnd"
    public static let gradientTypeKey = "gradientType", gradientBlendKey = "gradientBlend"
    public static let halftoneKind = "halftone", halftoneSizeKey = "halftoneSize", halftoneAngleKey = "halftoneAngle"
    public static let halftoneSoftnessKey = "halftoneSoftness", halftoneModeKey = "halftoneMode", halftoneBlendKey = "halftoneBlend"
    public static let tileKind = "tile", tileColumnsKey = "tileColumns", tileRowsKey = "tileRows"
    public static let tileOffsetXKey = "tileOffsetX", tileOffsetYKey = "tileOffsetY", tileMirrorKey = "tileMirror"
    public static let kaleidoscopeKind = "kaleidoscope", kaleidoCenterKey = "kaleidoCenter", kaleidoSegmentsKey = "kaleidoSegments"
    public static let kaleidoAngleKey = "kaleidoAngle", kaleidoZoomKey = "kaleidoZoom"
    public static let edgeFeatherKind = "edgeFeather", edgeFeatherAmountKey = "edgeFeatherAmount"
    public static let glitchKind = "glitchDisplace", glitchAmountKey = "glitchAmount", glitchBlockKey = "glitchBlock"
    public static let glitchSplitKey = "glitchSplit", glitchDensityKey = "glitchDensity", glitchRateKey = "glitchRate"
    public static let glitchSeedKey = "glitchSeed"
    // C5 (v64). "alphaOutline", not "outline": text and graphics already use "outline" for their own stroke style ids.
    public static let outlineKind = "alphaOutline", outlineWidthKey = "outlineWidth", outlineColorKey = "outlineColor"
    public static let outlineSoftnessKey = "outlineSoftness", outlinePositionKey = "outlinePosition"
    public static let longShadowKind = "longShadow", longShadowAngleKey = "longShadowAngle", longShadowLengthKey = "longShadowLength"
    public static let longShadowColorKey = "longShadowColor", longShadowFadeKey = "longShadowFade", longShadowOpacityKey = "longShadowOpacity"
}

public enum StyleEffects {
    static func slider(_ key: String, _ title: String, _ unit: String, _ d: Double, _ r: ClosedRange<Double>,
                       _ step: Double = 1, _ decimals: Int = 0) -> EffectParamSpec {
        EffectParamSpec(key: key, title: title, unit: unit, defaultValue: d, range: r, step: step, decimals: decimals)
    }
    static let deg = "\u{00B0}"

    public static let invertChannels = ["RGB", "Red", "Green", "Blue", "Alpha"]
    public static let waveTypes = ["Sine", "Square", "Triangle", "Sawtooth"]
    public static let wavePinnings = ["None", "All Edges", "Horizontal Edges", "Vertical Edges"]
    public static let gradientTypes = ["Linear", "Radial"]
    public static let strobeOperators = ["Copy", "Add", "Multiply", "Screen", "Difference"]
    public static let outlinePositions = ["Outside", "Inside", "Center"]

    public static let specs: [EffectSpec] = [
        // Lumetri's Vignette as its own effect: Amount in stops (negative darkens the edges, positive lightens them),
        // Midpoint = where the falloff sits, Roundness 0 = the frame's ellipse (+ circle, - rounded rectangle), Feather = width.
        EffectSpec(kind: ClipEffect.vignetteKind, title: "Vignette", params: [
            slider(ClipEffect.vignetteAmountKey, "Amount", "", -1.5, -5...5, 0.1, 1),
            slider(ClipEffect.vignetteMidpointKey, "Midpoint", "", 50, 0...100),
            slider(ClipEffect.vignetteRoundnessKey, "Roundness", "", 0, -100...100),
            slider(ClipEffect.vignetteFeatherKey, "Feather", "", 50, 0...100),
        ]),
        // Film Grain: soft, resolution-independent grain (Size in px of the clip), a new pattern each frame; Response
        // keeps it out of the deepest shadows and brightest highlights like film does.
        EffectSpec(kind: ClipEffect.grainKind, title: "Film Grain", params: [
            slider(ClipEffect.grainAmountKey, "Amount", "%", 30, 0...100, 0.5, 1),
            slider(ClipEffect.grainSizeKey, "Size", "px", 1.5, 0.5...20, 0.1, 1),
            slider(ClipEffect.grainSoftnessKey, "Softness", "%", 40, 0...100),
            slider(ClipEffect.grainColorKey, "Color", "%", 0, 0...100),
            slider(ClipEffect.grainResponseKey, "Highlight/Shadow Protect", "%", 60, 0...100),
            .checkbox(ClipEffect.grainAnimateKey, "Animate", on: true),
        ]),
        // RGB Split (chromatic aberration): red one way, blue the other. Radial = lens-like, growing towards the corners.
        EffectSpec(kind: ClipEffect.rgbSplitKind, title: "RGB Split", params: [
            slider(ClipEffect.rgbSplitAmountKey, "Amount", "px", 8, 0...1_000, 0.5, 1),
            slider(ClipEffect.rgbSplitAngleKey, "Angle", deg, 90, -3_600...3_600),
            .choice(ClipEffect.rgbSplitModeKey, "Mode", ["Linear", "Radial"]),
            slider(ClipEffect.rgbSplitBlendKey, "Blend With Original", "%", 0, 0...100),
        ]),
        // Premiere's Radial Blur: Spin smears Amount degrees around Center, Zoom along the line to it (Amount % of the
        // distance). Antialiasing High takes twice the taps.
        EffectSpec(kind: ClipEffect.radialBlurKind, title: "Radial Blur", params: [
            slider(ClipEffect.radialAmountKey, "Amount", "", 10, 0...100, 0.5, 1),
            .point(ClipEffect.radialCenterKey, "Center"),
            .choice(ClipEffect.radialTypeKey, "Type", ["Spin", "Zoom"]),
            .choice(ClipEffect.radialQualityKey, "Antialiasing (Best Quality)", ["Low", "High"]),
        ]),
        EffectSpec(kind: ClipEffect.horizontalFlipKind, title: "Horizontal Flip", params: []),
        EffectSpec(kind: ClipEffect.verticalFlipKind, title: "Vertical Flip", params: []),
        EffectSpec(kind: ClipEffect.invertKind, title: "Invert", params: [
            .choice(ClipEffect.invertChannelKey, "Channel", invertChannels),
            slider(ClipEffect.invertBlendKey, "Blend With Original", "%", 0, 0...100),
        ]),
        EffectSpec(kind: ClipEffect.posterizeKind, title: "Posterize", params: [
            slider(ClipEffect.posterizeLevelKey, "Level", "", 7, 2...255),
        ]),
        // Premiere's Tint: the picture's luminance mapped from Map Black To to Map White To (duotone), Amount to Tint mixed in.
        EffectSpec(kind: ClipEffect.tintKind, title: "Duotone", params: [
            .color(ClipEffect.tintBlackKey, "Map Black To", .black),
            .color(ClipEffect.tintWhiteKey, "Map White To", .white),
            slider(ClipEffect.tintAmountKey, "Amount to Duotone", "%", 100, 0...100, 0.5, 1),
        ]),
        EffectSpec(kind: ClipEffect.blackAndWhiteKind, title: "Black & White", params: []),
        EffectSpec(kind: ClipEffect.brightnessContrastKind, title: "Brightness & Contrast", params: [
            slider(ClipEffect.brightnessKey, "Brightness", "", 0, -100...100, 0.5, 1),
            slider(ClipEffect.contrastKey, "Contrast", "", 0, -100...100, 0.5, 1),
        ]),
        // Premiere's Twirl: strongest at Twirl Center, none at Twirl Radius (% of the longer side; 50 reaches the edges).
        EffectSpec(kind: ClipEffect.twirlKind, title: "Twirl", params: [
            slider(ClipEffect.twirlAngleKey, "Angle", deg, 0, -36_000...36_000),
            slider(ClipEffect.twirlRadiusKey, "Twirl Radius", "", 50, 0...100, 0.5, 1),
            .point(ClipEffect.twirlCenterKey, "Twirl Center"),
        ]),
        // Corner Warp: the four corners move by their offsets (px) and the picture is stretched to the new quadrilateral
        // in perspective; outside it is transparent. All offsets zero = the picture as it is (the drop-in default).
        EffectSpec(kind: ClipEffect.cornerPinKind, title: "Corner Warp", params: [
            .point(ClipEffect.cornerPinTopLeftKey, "Top Left"),
            .point(ClipEffect.cornerPinTopRightKey, "Top Right"),
            .point(ClipEffect.cornerPinBottomRightKey, "Bottom Right"),
            .point(ClipEffect.cornerPinBottomLeftKey, "Bottom Left"),
        ]),
        // Premiere's Wave Warp: waves travel along Direction (90 = right), the picture moves across it by Wave Height px;
        // Wave Width is the wavelength, Wave Speed cycles per second, Phase where the cycle starts. Pinning holds edges still.
        EffectSpec(kind: ClipEffect.waveWarpKind, title: "Wave Warp", params: [
            .choice(ClipEffect.waveTypeKey, "Wave Type", waveTypes),
            slider(ClipEffect.waveHeightKey, "Wave Height", "px", 10, -1_000...1_000),
            slider(ClipEffect.waveWidthKey, "Wave Width", "px", 40, 1...10_000),
            slider(ClipEffect.waveDirectionKey, "Direction", deg, 90, -3_600...3_600),
            slider(ClipEffect.waveSpeedKey, "Wave Speed", "", 1, -100...100, 0.1, 1),
            .choice(ClipEffect.wavePinningKey, "Pinning", wavePinnings),
            slider(ClipEffect.wavePhaseKey, "Phase", deg, 0, -36_000...36_000),
        ]),
        // Spherize: a lens bulge of Radius px around Center; Strength (extra) below 0 pinches.
        EffectSpec(kind: ClipEffect.spherizeKind, title: "Spherize", params: [
            slider(ClipEffect.spherizeRadiusKey, "Radius", "px", 0, 0...10_000),
            .point(ClipEffect.spherizeCenterKey, "Center of Sphere"),
            slider(ClipEffect.spherizeStrengthKey, "Strength", "%", 100, -100...100),
        ]),
        // Premiere's Strobe Light: flashes Strobe Duration seconds every Strobe Period; Random Strobe Probability makes
        // only some periods flash (always the same ones).
        EffectSpec(kind: ClipEffect.strobeKind, title: "Strobe Light", params: [
            .color(ClipEffect.strobeColorKey, "Strobe Color", .white),
            slider(ClipEffect.strobeBlendKey, "Blend With Original", "%", 0, 0...100),
            slider(ClipEffect.strobeDurationKey, "Strobe Duration", "s", 0.05, 0...60, 0.01, 2),
            slider(ClipEffect.strobePeriodKey, "Strobe Period", "s", 0.1, 0.01...60, 0.01, 2),
            slider(ClipEffect.strobeRandomKey, "Random Strobe Probability", "%", 0, 0...100),
            .choice(ClipEffect.strobeModeKey, "Strobe", ["Operates on Color Only", "Makes Layer Transparent"]),
            .choice(ClipEffect.strobeOperatorKey, "Strobe Operator", strobeOperators),
        ]),
        EffectSpec(kind: ClipEffect.alphaAdjustKind, title: "Transparency", params: [
            slider(ClipEffect.alphaOpacityKey, "Opacity", "%", 100, 0...100, 0.5, 1),
            .checkbox(ClipEffect.alphaIgnoreKey, "Ignore Alpha"),
            .checkbox(ClipEffect.alphaInvertKey, "Invert Alpha"),
            .checkbox(ClipEffect.alphaMaskOnlyKey, "Mask Only"),
        ]),
        // Premiere's Lens Distortion: Curvature below 0 bulges the picture like a fisheye, above 0 pinches it (pincushion);
        // decentering moves the lens center (% of half the frame). Fill Alpha leaves uncovered corners transparent.
        EffectSpec(kind: ClipEffect.lensDistortionKind, title: "Lens Distortion", params: [
            slider(ClipEffect.lensCurvatureKey, "Curvature", "", 0, -100...100),
            slider(ClipEffect.lensVDecenterKey, "Vertical Decentering", "", 0, -100...100),
            slider(ClipEffect.lensHDecenterKey, "Horizontal Decentering", "", 0, -100...100),
            .checkbox(ClipEffect.lensFillAlphaKey, "Fill Alpha", on: true),
            .color(ClipEffect.lensFillColorKey, "Fill Color", .white),
            .checkbox(ClipEffect.lensAutoScaleKey, "Auto Scale"),      // F7.15: zoom about the lens center until no empty edge shows
        ]),
        // Gradient: a linear or radial ramp from Start Color at Start Point to End Color at End Point, mixed over the picture
        // by Opacity (100 = the ramp replaces the colors; the picture's own alpha is kept). Points are px from the frame center.
        EffectSpec(kind: ClipEffect.gradientKind, title: "Gradient", params: [
            .choice(ClipEffect.gradientTypeKey, "Type", gradientTypes),
            .color(ClipEffect.gradientColor1Key, "Start Color", .black),
            .color(ClipEffect.gradientColor2Key, "End Color", .white),
            .point(ClipEffect.gradientStartKey, "Start Point", Vec2(0, -400)),
            .point(ClipEffect.gradientEndKey, "End Point", Vec2(0, 400)),
            slider(ClipEffect.gradientBlendKey, "Opacity", "%", 100, 0...100, 0.5, 1),
        ]),
        // Light Leak: a warm, soft light washing in from one side (screen blend), drifting with Speed; Seed picks the path.
        EffectSpec(kind: ClipEffect.lightLeakKind, title: "Light Leak", params: [
            .color(ClipEffect.leakColor1Key, "Color 1", EffectColor(red: 1, green: 0.55, blue: 0.15)),
            .color(ClipEffect.leakColor2Key, "Color 2", EffectColor(red: 1, green: 0.25, blue: 0.45)),
            slider(ClipEffect.leakIntensityKey, "Intensity", "%", 70, 0...200),
            slider(ClipEffect.leakAngleKey, "From", deg, 300, -3_600...3_600),
            slider(ClipEffect.leakSizeKey, "Size", "%", 60, 1...300),
            slider(ClipEffect.leakSpeedKey, "Speed", "", 1, 0...20, 0.1, 1),
            slider(ClipEffect.leakSeedKey, "Seed", "", 1, 0...10_000),
        ]),
        // Halftone: a rotated dot screen. Dots grow with the shadows (Black & White: ink on paper) or with the highlights
        // (Color: the picture's own colors as dots on black). Size = dot pitch in px, Softness = edge width.
        EffectSpec(kind: ClipEffect.halftoneKind, title: "Halftone", params: [
            slider(ClipEffect.halftoneSizeKey, "Dot Size", "px", 12, 2...200, 0.5, 1),
            slider(ClipEffect.halftoneAngleKey, "Angle", deg, 45, -3_600...3_600),
            slider(ClipEffect.halftoneSoftnessKey, "Softness", "%", 20, 0...100),
            .choice(ClipEffect.halftoneModeKey, "Mode", halftoneModes),
            slider(ClipEffect.halftoneBlendKey, "Amount", "%", 100, 0...100, 0.5, 1),
        ]),
        // Tile: the whole picture repeated Columns x Rows times (fractions allowed, so it can zoom smoothly); Offset scrolls
        // it by a share of one tile; Mirror Edges flips every second tile so the seams match.
        EffectSpec(kind: ClipEffect.tileKind, title: "Tile", params: [
            slider(ClipEffect.tileColumnsKey, "Columns", "", 2, 1...20, 0.1, 1),
            slider(ClipEffect.tileRowsKey, "Rows", "", 2, 1...20, 0.1, 1),
            slider(ClipEffect.tileOffsetXKey, "Offset X", "%", 0, -1_000...1_000, 0.5, 1),
            slider(ClipEffect.tileOffsetYKey, "Offset Y", "%", 0, -1_000...1_000, 0.5, 1),
            .checkbox(ClipEffect.tileMirrorKey, "Mirror Edges"),
        ]),
        // Kaleidoscope: one wedge of the picture mirrored around Center into Segments slices; Angle turns which wedge is
        // read, Zoom scales it.
        EffectSpec(kind: ClipEffect.kaleidoscopeKind, title: "Kaleidoscope", params: [
            .point(ClipEffect.kaleidoCenterKey, "Center"),
            slider(ClipEffect.kaleidoSegmentsKey, "Segments", "", 6, 2...32),
            slider(ClipEffect.kaleidoAngleKey, "Angle", deg, 0, -36_000...36_000),
            slider(ClipEffect.kaleidoZoomKey, "Zoom", "%", 100, 10...400, 0.5, 1),
        ]),
        // Edge Feather: the picture's own edges fade to transparent over Feather px (a soft frame, no mask needed).
        EffectSpec(kind: ClipEffect.edgeFeatherKind, title: "Edge Feather", params: [
            slider(ClipEffect.edgeFeatherAmountKey, "Feather", "px", 40, 0...2_000, 0.5, 1),
        ]),
        // Glitch Displace: horizontal bands of Block Height px slide sideways by up to Amount px (Density = share of bands),
        // red and blue split Chroma Split px; the pattern changes Rate times a second (0 holds it), Seed picks another one.
        EffectSpec(kind: ClipEffect.glitchKind, title: "Glitch Displace", params: [
            slider(ClipEffect.glitchAmountKey, "Amount", "px", 30, 0...2_000, 0.5, 1),
            slider(ClipEffect.glitchBlockKey, "Block Height", "px", 24, 1...500, 0.5, 1),
            slider(ClipEffect.glitchSplitKey, "Chroma Split", "px", 6, 0...200, 0.5, 1),
            slider(ClipEffect.glitchDensityKey, "Density", "%", 40, 0...100),
            slider(ClipEffect.glitchRateKey, "Rate", "", 8, 0...60, 0.5, 1),
            slider(ClipEffect.glitchSeedKey, "Seed", "", 1, 0...10_000),
        ]),
        // C5 Outline: a stroke around the picture's alpha edge (cutouts, stickers, keyed footage; on a full frame it frames
        // the picture). Text and shapes keep their own stroke in the Graphics panel.
        EffectSpec(kind: ClipEffect.outlineKind, title: "Outline", params: [
            slider(ClipEffect.outlineWidthKey, "Width", "px", 12, 0...500, 0.5, 1),
            .color(ClipEffect.outlineColorKey, "Color", .white),
            slider(ClipEffect.outlineSoftnessKey, "Softness", "px", 0, 0...200, 0.5, 1),
            .choice(ClipEffect.outlinePositionKey, "Position", outlinePositions),
        ]),
        // C5 Long Shadow: the silhouette dragged along Angle (0 = up, clockwise) for Length px, fading out by Fade.
        EffectSpec(kind: ClipEffect.longShadowKind, title: "Long Shadow", params: [
            slider(ClipEffect.longShadowAngleKey, "Angle", deg, 135, -3_600...3_600),
            slider(ClipEffect.longShadowLengthKey, "Length", "px", 200, 0...4_000, 0.5, 1),
            .color(ClipEffect.longShadowColorKey, "Color", .black),
            slider(ClipEffect.longShadowFadeKey, "Fade", "%", 50, 0...100),
            slider(ClipEffect.longShadowOpacityKey, "Opacity", "%", 80, 0...100),
        ]),
    ]
    public static let halftoneModes = ["Black & White", "Color"]

    /// Hash of a strobe period index to 0..<1 (deterministic, so the same periods flash on every render).
    static func periodHash(_ i: Int64) -> Double {
        var z = UInt64(bitPattern: i) &* 0x9E37_79B9_7F4A_7C15
        z ^= z >> 30; z &*= 0xBF58_476D_1CE4_E5B9; z ^= z >> 27; z &*= 0x94D0_49BB_1331_11EB; z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

extension ClipEffect {
    /// The FB-T2 filter this effect makes at clip-local `t`, or nil when it is not such an effect or does nothing.
    func styleFilter(atLocal t: Time) -> ImageFilter? {
        func v(_ key: String) -> Double { scalar(key, atLocal: t) }
        let seconds = KeyframeMath.seconds(t)
        switch kind {
        case Self.vignetteKind:
            let a = v(Self.vignetteAmountKey)
            guard a != 0 else { return nil }
            return .vignette(amount: a, midpoint: v(Self.vignetteMidpointKey) / 100, roundness: v(Self.vignetteRoundnessKey) / 100,
                             feather: v(Self.vignetteFeatherKey) / 100)
        case Self.rgbSplitKind:
            let len = v(Self.rgbSplitAmountKey), mix = v(Self.rgbSplitBlendKey) / 100
            guard len > 0, mix < 1 else { return nil }
            let a = v(Self.rgbSplitAngleKey) * .pi / 180
            // Premiere's angle convention: 0 = up, clockwise; the default 90 puts red to the right, blue to the left.
            return .rgbSplit(dx: len * sin(a), dy: -len * cos(a), radial: choice(Self.rgbSplitModeKey, atLocal: t) == 1, mix: mix)
        case Self.radialBlurKind:
            let a = v(Self.radialAmountKey)
            guard a > 0 else { return nil }
            return .radialBlur(center: point(Self.radialCenterKey, atLocal: t), amount: a,
                               zoom: choice(Self.radialTypeKey, atLocal: t) == 1, high: choice(Self.radialQualityKey, atLocal: t) == 1)
        case Self.horizontalFlipKind: return .flip(horizontal: true, vertical: false)
        case Self.verticalFlipKind: return .flip(horizontal: false, vertical: true)
        case Self.invertKind:
            let blend = v(Self.invertBlendKey) / 100
            guard blend < 1 else { return nil }
            return .invert(channel: choice(Self.invertChannelKey, atLocal: t), blend: blend)
        case Self.posterizeKind:
            return .posterize(levels: Int(v(Self.posterizeLevelKey).rounded()))
        case Self.tintKind:
            let a = v(Self.tintAmountKey) / 100
            guard a > 0 else { return nil }
            return .tint(black: color(Self.tintBlackKey, atLocal: t).rgb, white: color(Self.tintWhiteKey, atLocal: t).rgb, amount: a)
        case Self.blackAndWhiteKind:
            return .tint(black: .zero, white: SIMD3(1, 1, 1), amount: 1)
        case Self.brightnessContrastKind:
            let b = v(Self.brightnessKey), c = v(Self.contrastKey)
            guard b != 0 || c != 0 else { return nil }
            return .brightnessContrast(brightness: b / 100, contrast: c / 100)
        case Self.twirlKind:
            let a = v(Self.twirlAngleKey), r = v(Self.twirlRadiusKey) / 100
            guard a != 0, r > 0 else { return nil }
            return .twirl(center: point(Self.twirlCenterKey, atLocal: t), angle: a, radius: r)
        case Self.cornerPinKind:
            let tl = point(Self.cornerPinTopLeftKey, atLocal: t), tr = point(Self.cornerPinTopRightKey, atLocal: t)
            let br = point(Self.cornerPinBottomRightKey, atLocal: t), bl = point(Self.cornerPinBottomLeftKey, atLocal: t)
            guard tl != .zero || tr != .zero || br != .zero || bl != .zero else { return nil }
            return .cornerPin(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
        case Self.waveWarpKind:
            let h = v(Self.waveHeightKey)
            guard h != 0 else { return nil }
            var phase = (v(Self.wavePhaseKey) / 360 + v(Self.waveSpeedKey) * seconds).truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
            return .waveWarp(type: choice(Self.waveTypeKey, atLocal: t), height: h, width: v(Self.waveWidthKey),
                             direction: v(Self.waveDirectionKey), phase: phase, pinning: choice(Self.wavePinningKey, atLocal: t))
        case Self.spherizeKind:
            let r = v(Self.spherizeRadiusKey), s = v(Self.spherizeStrengthKey) / 100
            guard r > 0, s != 0 else { return nil }
            return .spherize(center: point(Self.spherizeCenterKey, atLocal: t), radius: r, strength: s)
        case Self.strobeKind:
            let period = v(Self.strobePeriodKey), duration = v(Self.strobeDurationKey), blend = v(Self.strobeBlendKey) / 100
            guard duration > 0, blend < 1 else { return nil }
            let index = floor(seconds / period)
            guard seconds - index * period < duration else { return nil }
            let p = v(Self.strobeRandomKey) / 100
            if p > 0, StyleEffects.periodHash(Int64(index)) >= p { return nil }
            return .strobe(color: color(Self.strobeColorKey, atLocal: t).rgb, blend: blend,
                           op: choice(Self.strobeOperatorKey, atLocal: t), transparent: choice(Self.strobeModeKey, atLocal: t) == 1)
        case Self.lensDistortionKind:
            let c = v(Self.lensCurvatureKey)
            guard c != 0 else { return nil }
            return .lensDistortion(curvature: c / 100, decenter: Vec2(v(Self.lensHDecenterKey) / 100, v(Self.lensVDecenterKey) / 100),
                                   fillAlpha: flag(Self.lensFillAlphaKey, atLocal: t), fill: color(Self.lensFillColorKey, atLocal: t).rgb,
                                   autoScale: flag(Self.lensAutoScaleKey, atLocal: t),
                                   exactModel: flag(Self.lensModelKey, atLocal: t) || flag(Self.lensAutoScaleKey, atLocal: t))
        case Self.lightLeakKind:
            let i = v(Self.leakIntensityKey) / 100
            guard i > 0 else { return nil }
            // The leak's center sits outside the frame towards From and wanders on a smooth seeded path (share of half the frame).
            let a = v(Self.leakAngleKey) * .pi / 180, seed = UInt64(max(v(Self.leakSeedKey), 0).rounded())
            let x = v(Self.leakSpeedKey) * seconds * 0.35
            let wander = Vec2(MotionEffects.noise(x, seed: seed &* 2 &+ 1), MotionEffects.noise(x, seed: seed &* 2 &+ 2)) * 0.45
            let center = Vec2(sin(a), -cos(a)) * 0.9 + wander
            let swirl = MotionEffects.noise(x * 0.7, seed: seed &* 2 &+ 7) * 0.6
            return .lightLeak(color1: color(Self.leakColor1Key, atLocal: t).rgb, color2: color(Self.leakColor2Key, atLocal: t).rgb,
                              intensity: i, center: center, size: v(Self.leakSizeKey) / 100, angle: a + swirl)
        case Self.gradientKind:
            let b = v(Self.gradientBlendKey) / 100
            guard b > 0 else { return nil }
            return .gradient(color1: color(Self.gradientColor1Key, atLocal: t).rgb, color2: color(Self.gradientColor2Key, atLocal: t).rgb,
                             start: point(Self.gradientStartKey, atLocal: t), end: point(Self.gradientEndKey, atLocal: t),
                             radial: choice(Self.gradientTypeKey, atLocal: t) == 1, blend: b)
        case Self.halftoneKind:
            let b = v(Self.halftoneBlendKey) / 100, size = v(Self.halftoneSizeKey)
            guard b > 0, size > 0 else { return nil }
            return .halftone(size: size, angle: v(Self.halftoneAngleKey), softness: v(Self.halftoneSoftnessKey) / 100,
                             color: choice(Self.halftoneModeKey, atLocal: t) == 1, blend: b)
        case Self.tileKind:
            let c = max(v(Self.tileColumnsKey), 0.01), r = max(v(Self.tileRowsKey), 0.01)
            let off = Vec2(v(Self.tileOffsetXKey) / 100, v(Self.tileOffsetYKey) / 100)
            guard c != 1 || r != 1 || off != .zero else { return nil }
            return .tile(columns: c, rows: r, offset: off, mirror: flag(Self.tileMirrorKey, atLocal: t))
        case Self.kaleidoscopeKind:
            return .kaleidoscope(center: point(Self.kaleidoCenterKey, atLocal: t), segments: max(2, Int(v(Self.kaleidoSegmentsKey).rounded())),
                                 angle: v(Self.kaleidoAngleKey), zoom: max(v(Self.kaleidoZoomKey), 1) / 100)
        case Self.edgeFeatherKind:
            let a = v(Self.edgeFeatherAmountKey)
            guard a > 0 else { return nil }
            return .edgeFeather(amount: a)
        case Self.glitchKind:
            let amount = v(Self.glitchAmountKey), split = v(Self.glitchSplitKey), density = v(Self.glitchDensityKey) / 100
            guard (amount > 0 && density > 0) || split > 0 else { return nil }
            let step = Int(floor(seconds * max(v(Self.glitchRateKey), 0)))
            return .glitch(amount: amount, block: max(v(Self.glitchBlockKey), 1), split: split, density: min(density, 1),
                           seed: Int(max(v(Self.glitchSeedKey), 0).rounded()) + step)
        case Self.outlineKind:
            let w = v(Self.outlineWidthKey)
            guard w > 0 else { return nil }
            return .outline(width: w, color: color(Self.outlineColorKey, atLocal: t).rgb, softness: v(Self.outlineSoftnessKey),
                            position: ImageFilter.OutlinePosition(rawValue: choice(Self.outlinePositionKey, atLocal: t)) ?? .outside)
        case Self.longShadowKind:
            let len = v(Self.longShadowLengthKey), o = v(Self.longShadowOpacityKey) / 100
            guard len > 0, o > 0 else { return nil }
            return .longShadow(angle: v(Self.longShadowAngleKey), length: len, color: color(Self.longShadowColorKey, atLocal: t).rgb,
                               fade: v(Self.longShadowFadeKey) / 100, opacity: o)
        case Self.alphaAdjustKind:
            let o = v(Self.alphaOpacityKey) / 100
            let ignore = flag(Self.alphaIgnoreKey, atLocal: t), inv = flag(Self.alphaInvertKey, atLocal: t)
            let only = flag(Self.alphaMaskOnlyKey, atLocal: t)
            guard o < 1 || ignore || inv || only else { return nil }
            return .alphaAdjust(opacity: o, ignore: ignore, invert: inv, maskOnly: only)
        default:
            return nil
        }
    }
}

extension Project {
    /// Any clip carries a Gradient effect: the file must be v51.
    public var containsGradientEffects: Bool {
        allClips().contains { c in c.effects.contains { $0.kind == ClipEffect.gradientKind } }
    }
}
