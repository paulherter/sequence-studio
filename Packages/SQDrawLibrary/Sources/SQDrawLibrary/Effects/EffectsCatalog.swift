import Foundation
import SQCore
import SQText
import SQUIKit
import SQLibrary
import SQEditorSession

/// One row of the Effects panel list (and of the Text panel's template list): the AppKit `TemplateListPanelView` and
/// the draw panel (`EffectsDrawPanel`) show the same rows.
public struct EffectsRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var symbol: SQIcon
    /// A category heading: not selectable, not draggable.
    public var isHeader: Bool
    /// Effects panel outline: indentation level, folder rows (click toggles them), and the effect id the row stands for
    /// (`id` is unique per row; the same effect can sit in several folders).
    public var depth = 0
    public var isFolder = false
    public var isExpanded = false
    public var payload: String?
    /// Section rows of the Effects panel: number of entries inside (hits while searching), shown at the right.
    public var count: Int?
    /// A user folder row, or an item inside one.
    public var userFolder: UUID?
    public var itemID: String { payload ?? id }
    public init(id: String, title: String, subtitle: String = "", symbol: SQIcon, isHeader: Bool = false) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.isHeader = isHeader
    }
}

/// One thing the Effects panel offers: an effect kind, a transition, a built-in or saved preset, a text Look.
public struct EffectsEntry: Sendable, Hashable {
    public var id: String, title: String, category: String, symbol: SQIcon
    public init(id: String, title: String, category: String, symbol: SQIcon) {
        self.id = id; self.title = title; self.category = category; self.symbol = symbol
    }
    /// Search hit: the query is inside the title, the category (or its shown name) or one of the effect's other names
    /// (`EffectSearchTerms`: "stabilize", "steady", "camera shake" all find the Stabilizer).
    public func matches(query q: String) -> Bool {
        q.isEmpty || title.lowercased().contains(q) || category.lowercased().contains(q)
            || EffectFolderOutline.displayName(category).lowercased().contains(q)
            || EffectSearchTerms.terms(forKind: id).contains { $0.contains(q) }
    }
}

/// What the Effects panel lists, shared by the AppKit panel (`EffectsPanelView` forwards here) and the draw panel.
public enum EffectsCatalog {
    public typealias Entry = EffectsEntry
    public typealias Row = EffectsRow

    /// Everything that can be applied today: video effects, audio effects (AUDIO-FX), then transitions.
    /// Hidden effects (`HiddenCatalog`: duplicates of another effect) are not listed; stored ones still work.
    public static let catalog: [Entry] = offered(hiding: HiddenCatalog.isActive)
    /// The same list for an explicit switch (tests; `catalog` uses the app-level default).
    public static func offered(hiding: Bool) -> [Entry] {
        (lookEntries + videoEntries + audioEntries + transitionEntries).filter { !HiddenCatalog.isHidden(effectKind: $0.id, active: hiding) }
    }

    /// Text Looks (style only) and Text Animations (motion only), by family: dragged onto a text layer, they stack.
    /// Ids are `textlook.<id>` / `textanim.<id>` (`TextPresetCatalog`).
    public static let textPresetEntries: [Entry] = !BuiltInTextLooks.isEnabled ? [] :
        TextPresetCategory.allCases.flatMap { c in
            TextPresetCatalog.looks(in: c).map { Entry(id: TextPresetCatalog.lookID($0), title: $0.name, category: "Looks - \(c.title)" + (TextLookGenerator.family(ofLookID: $0.id).map { " - \($0)" } ?? ""), symbol: .text) }
        } + TextPresetCategory.allCases.flatMap { c in
            TextPresetCatalog.motions(in: c).map { Entry(id: TextPresetCatalog.motionID($0), title: $0.name, category: "Animations - \(c.title)", symbol: .text) }
        }

    /// AUDIO-FX: the "Audio Effects" folder, in Premiere's sub-folders. Ids are the `audio.` effect kinds.
    public static let audioEntries: [Entry] = stackPresetEntries([.voice]) + [
        Entry(id: ClipEffect.audioCompressorKind, title: "Compressor", category: "Level", symbol: .foldVertical),
        Entry(id: ClipEffect.audioDeEsserKind, title: "De-Esser", category: "Level", symbol: .voice),
        Entry(id: ClipEffect.audioGainKind, title: "Gain", category: "Level", symbol: .volume),
        Entry(id: ClipEffect.audioLimiterKind, title: "Limiter", category: "Level", symbol: .waveformLines),
        Entry(id: ClipEffect.audioEQKind, title: "EQ (3 band)", category: "Tone", symbol: .slidersVertical),
        Entry(id: ClipEffect.audioParametricEQKind, title: "EQ", category: "Tone", symbol: .slidersVertical),
        Entry(id: ClipEffect.audioGraphicEQKind, title: "Graphic EQ", category: "Tone", symbol: .slidersVertical),
        Entry(id: ClipEffect.audioMultibandKind, title: "Multiband Compressor", category: "Level", symbol: .chartBars),
        Entry(id: ClipEffect.audioEnhanceSpeechKind, title: "Enhance Speech", category: "Cleanup", symbol: .toolMask),
        Entry(id: ClipEffect.audioNoiseReductionKind, title: "Noise Reduction", category: "Cleanup", symbol: .activity),
        Entry(id: ClipEffect.audioNoiseGateKind, title: "Noise Gate", category: "Cleanup", symbol: .waveformLines),
        Entry(id: ClipEffect.audioDeHumKind, title: "De-Hum", category: "Cleanup", symbol: .zapOff),
        Entry(id: ClipEffect.audioDeReverbKind, title: "De-Reverb", category: "Cleanup", symbol: .waveformLines),
        Entry(id: ClipEffect.audioLowCutKind, title: "Low Cut", category: "Cleanup", symbol: .arrowUpRight),
        Entry(id: ClipEffect.audioNotchKind, title: "Notch", category: "Cleanup", symbol: .shapeLine),
        Entry(id: ClipEffect.audioHighCutKind, title: "High Cut", category: "Cleanup", symbol: .arrowDownRight),
        Entry(id: ClipEffect.audioDialogueLevelerKind, title: "Dialogue Leveler", category: "Level", symbol: .microphone),
        Entry(id: ClipEffect.audioDelayKind, title: "Delay", category: "Space", symbol: .loop),
        Entry(id: ClipEffect.audioReverbKind, title: "Reverb", category: "Space", symbol: .landmark),
        Entry(id: ClipEffect.audioStereoWidthKind, title: "Stereo Width", category: "Space", symbol: .moveHorizontal),
        Entry(id: ClipEffect.audioChorusKind, title: "Chorus", category: "Space", symbol: .activity),
        Entry(id: ClipEffect.audioPitchShiftKind, title: "Pitch Shift", category: "Tone", symbol: .waveform),
        Entry(id: ClipEffect.audioDisguiseVoiceKind, title: "Disguise Voice", category: "Tone", symbol: .drama),
    ]

    public static let videoEntries: [Entry] = [
        Entry(id: ClipEffect.gaussianBlurKind, title: "Blur", category: "Blur", symbol: .circleDotted),
        Entry(id: ClipEffect.directionalBlurKind, title: "Directional Blur", category: "Blur", symbol: .wind),
        Entry(id: ClipEffect.sharpenKind, title: "Sharpen", category: "Adjust", symbol: .triangle),
        Entry(id: ClipEffect.unsharpMaskKind, title: "Unsharp Mask", category: "Adjust", symbol: .triangle),
        Entry(id: ClipEffect.radialBlurKind, title: "Radial Blur", category: "Blur", symbol: .sunRays),
        Entry(id: ClipEffect.motionBlurKind, title: "Motion Blur", category: "Blur", symbol: .circleDashed),
        Entry(id: ClipEffect.invertKind, title: "Invert", category: "Adjust", symbol: .contrast),
        Entry(id: ClipEffect.colorKind, title: "Color", category: "Adjust", symbol: .palette),
        Entry(id: ClipEffect.brightnessContrastKind, title: "Brightness & Contrast", category: "Adjust", symbol: .sunDim),
        Entry(id: ClipEffect.tintKind, title: "Duotone", category: "Adjust", symbol: .droplet),
        Entry(id: ClipEffect.lensDistortionKind, title: "Lens Distortion", category: "Distort", symbol: .aperture),
        Entry(id: ClipEffect.mirrorKind, title: "Mirror", category: "Distort", symbol: .flipHorizontal),
        Entry(id: ClipEffect.spherizeKind, title: "Spherize", category: "Distort", symbol: .circleDot),
        Entry(id: ClipEffect.twirlKind, title: "Twirl", category: "Distort", symbol: .tornado),
        Entry(id: ClipEffect.waveWarpKind, title: "Wave Warp", category: "Distort", symbol: .waves),
        Entry(id: ClipEffect.blackAndWhiteKind, title: "Black & White", category: "Adjust", symbol: .contrast),
        Entry(id: ClipEffect.alphaAdjustKind, title: "Transparency", category: "Cutout", symbol: .checkerboard),
        Entry(id: ClipEffect.ultraKeyKind, title: "Color Key", category: "Cutout", symbol: .user),
        Entry(id: ClipEffect.lumaKeyKind, title: "Luma Key", category: "Cutout", symbol: .contrast),
        Entry(id: ClipEffect.trackMaskKind, title: "Track Mask", category: "Cutout", symbol: .stack),
        Entry(id: ClipEffect.grainKind, title: "Film Grain", category: "Grain", symbol: .grain),
        Entry(id: ClipEffect.noiseKind, title: "Noise", category: "Grain", symbol: .grain),
        Entry(id: ClipEffect.dropShadowKind, title: "Drop Shadow", category: "Stylize", symbol: .ungroup),
        Entry(id: ClipEffect.longShadowKind, title: "Long Shadow", category: "Stylize", symbol: .stack),
        Entry(id: ClipEffect.outlineKind, title: "Outline", category: "Stylize", symbol: .squareDashed),
        Entry(id: ClipEffect.glowKind, title: "Glow", category: "Stylize", symbol: .sunRays),
        Entry(id: ClipEffect.gradientKind, title: "Gradient", category: "Stylize", symbol: .panelBottom),
        Entry(id: ClipEffect.lightLeakKind, title: "Light Leak", category: "Stylize", symbol: .sunMedium),
        Entry(id: ClipEffect.mosaicKind, title: "Mosaic", category: "Stylize", symbol: .grid3),
        Entry(id: ClipEffect.halftoneKind, title: "Halftone", category: "Stylize", symbol: .grain),
        Entry(id: ClipEffect.tileKind, title: "Tile", category: "Distort", symbol: .grid),
        Entry(id: ClipEffect.kaleidoscopeKind, title: "Kaleidoscope", category: "Distort", symbol: .hexagon),
        Entry(id: ClipEffect.cornerPinKind, title: "Corner Warp", category: "Distort", symbol: .hexagon),
        Entry(id: ClipEffect.glitchKind, title: "Glitch Displace", category: "Distort", symbol: .columns3),
        Entry(id: ClipEffect.edgeFeatherKind, title: "Edge Feather", category: "Stylize", symbol: .squareDashed),
        Entry(id: ClipEffect.posterizeKind, title: "Posterize", category: "Stylize", symbol: .stack),
        Entry(id: ClipEffect.rgbSplitKind, title: "RGB Split", category: "Stylize", symbol: .hexagon),
        Entry(id: ClipEffect.strobeKind, title: "Strobe Light", category: "Stylize", symbol: .zap),
        Entry(id: ClipEffect.vignetteKind, title: "Vignette", category: "Stylize", symbol: .circleDashed),
        Entry(id: ClipEffect.cropKind, title: "Crop", category: "Transform", symbol: .crop),
        Entry(id: ClipEffect.horizontalFlipKind, title: "Horizontal Flip", category: "Transform", symbol: .moveHorizontal),
        Entry(id: ClipEffect.roundedCornersKind, title: "Rounded Corners", category: "Transform", symbol: .roundedSquare),
        Entry(id: ClipEffect.stabilizeKind, title: "Stabilize", category: "Transform", symbol: .scan),
        Entry(id: ClipEffect.transformKind, title: "Transform", category: "Transform", symbol: .move),
        Entry(id: ClipEffect.verticalFlipKind, title: "Vertical Flip", category: "Transform", symbol: .moveVertical),
        // W7.4 / N3 parametric motion effects. FB-G: Move / Zoom / Pop / Fade are transitions now (Video Transitions).
        Entry(id: ClipEffect.shakeKind, title: "Shake", category: "Motion", symbol: .vibrate),
        Entry(id: ClipEffect.bounceKind, title: "Bounce", category: "Motion", symbol: .moveVertical),
        Entry(id: ClipEffect.pulseKind, title: "Pulse", category: "Motion", symbol: .radio),
        Entry(id: ClipEffect.wiggleKind, title: "Wiggle", category: "Motion", symbol: .waves),
        // Temporal clean-up (reads neighboring source frames).
        Entry(id: ClipEffect.videoDenoiseKind, title: "Video Denoise", category: "Repair", symbol: .toolMask),
        Entry(id: ClipEffect.deflickerKind, title: "Deflicker", category: "Repair", symbol: .lightbulb),
        // Time and burn-in: a stepped frame rate, and a camcorder date/time drawn by the text renderer.
        Entry(id: ClipEffect.posterizeTimeKind, title: "Posterize Time", category: "Time", symbol: .timer),
        Entry(id: ClipEffect.trailsKind, title: "Trails", category: "Time", symbol: .generator),
        Entry(id: ClipEffect.dateStampKind, title: "Date Stamp", category: "Stylize", symbol: .calendarClock),
    ]

    /// Film and tape looks: ready-made stacks (the presets) first, then the single effects they are built from.
    public static let lookEntries: [Entry] = stackPresetEntries([.looks]) + [
        Entry(id: ClipEffect.gateWeaveKind, title: "Gate Weave", category: "Film", symbol: .moveHorizontal),
        Entry(id: ClipEffect.agedFilmKind, title: "Aged Film", category: "Film", symbol: .film),
        Entry(id: ClipEffect.scanlinesKind, title: "Scanlines", category: "Tape & TV", symbol: .menu),
        Entry(id: ClipEffect.chromaBleedKind, title: "Chroma Bleed", category: "Tape & TV", symbol: .droplet),
        Entry(id: ClipEffect.trackingNoiseKind, title: "Tracking Noise", category: "Tape & TV", symbol: .activity),
    ]

    public static let transitionEntries: [Entry] = TransitionKind.allCases.map { k in
        Entry(id: EffectDragPayload.transitionID(k), title: k.name,
              category: k.trackKind == .video ? "Video Transitions" : "Audio Transitions", symbol: transitionSymbol(k))
    }

    public static func transitionSymbol(_ k: TransitionKind) -> SQIcon {
        switch k {
        case .quickFade: .zap
        case .push: .pushRight
        case .slide: .slideOut
        case .whip: .wind
        case .zoomIn: .zoomIn
        case .zoomOut: .zoomOut
        case .zoomPop: .zoomSparkle
        case .softWipe: .columns2
        case .glitch: .activity
        case .iris: .circleDashed
        case .lightLeak: .sunRays
        case .blurDissolve: .droplet
        case .dipToColour: .contrast
        case .flash: .zap
        case .spin: .refresh
        case .crossZoom: .maximize
        case .staticNoise: .tv
        case .lightNoise: .sparkles
        case .strobeCut: .lightbulb
        case .additiveDissolve: .sunMedium
        case .clockWipe: .clock
        case .boxIris: .squareDashed
        case .diamondIris: .diamond
        case .crossIris: .plus
        case .barnDoors: .columns3
        case .venetianBlinds: .list
        case .radialWipe: .circleDashed
        case .wedgeWipe: .sunRays
        case .pinwheel: .rotateCW
        case .checkerWipe: .checkerboard
        case .zigZagBlocks: .grid3
        case .insetWipe: .squareDashed
        case .randomBlocks: .grid
        case .sliceWipe: .list
        case .mosaicDissolve: .grid3
        case .flip3D: .rotateCW
        case .spring: .slideOut
        case .fall: .arrowRight
        case .burn: .sunMedium
        case .flare: .sunRays
        case .warp: .droplet
        case .shake: .zap
        case .stinger: .sequence
        case .move: .arrowRight
        case .zoom: .zoomIn
        case .pop: .sparkles
        default: k.trackKind == .video ? .group : .activity
        }
    }

    /// Flat rows for a search text: entries whose title or category contain it (case-insensitive), under their category
    /// heading. The panel itself shows the folder outline (`EffectFolderOutline`); this flat form stays for callers and tests.
    public static func rows(matching query: String, in entries: [Entry] = catalog) -> [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = entries.filter { $0.matches(query: q) }
        var out: [Row] = []
        var seen: [String] = []
        for e in hits where !seen.contains(e.category) { seen.append(e.category) }
        for c in seen {
            out.append(Row(id: "category-" + c, title: EffectFolderOutline.displayName(c), symbol: .folder, isHeader: true))
            out += hits.filter { $0.category == c }.map { Row(id: $0.id, title: $0.title, symbol: $0.symbol) }
        }
        return out
    }

    /// FB-T3: the built-in motion and keying presets (Whip In, Bounce In, Green Screen ...), listed first in the Presets
    /// folder. Ids `preset.builtin.<id>`.
    public static let builtInPresetEntries: [Entry] = stackPresetEntries([.motion, .keying])

    /// The one listing path of the built-in stack presets (`EffectStackPresets.offered`, hidden ones left out): row id,
    /// name, and the folder and icon of the preset's bin.
    public static func stackPresetEntries(_ bins: Set<EffectStackPreset.Bin>) -> [Entry] {
        EffectStackPresets.offered(in: bins).map { Entry(id: $0.rowID, title: $0.name, category: $0.bin.panelCategory, symbol: $0.bin.panelSymbol) }
    }

    /// The Library's saved presets as Effects panel entries (keystones stay in their own panel). Mirrors the Mac
    /// wiring in EditorPanels so both panels list the same "Presets" folder.
    public static func presetEntries(_ presets: [PresetItem]) -> [Entry] {
        presets.filter { $0.kind != .keystone }.map {
            Entry(id: "preset.\($0.id.uuidString)", title: $0.name, category: EffectFolderOutline.presetsFolder, symbol: .toolMask)
        }
    }
}

extension EffectStackPreset.Bin {
    /// The Effects panel folder a bin's presets are listed in (unchanged by consolidation step 8: film looks in Looks,
    /// everything else in Presets; Voice's Presets folder sits in the audio folder because its id is an audio id).
    public var panelCategory: String { self == .looks ? "Looks" : "Presets" }

    public var panelSymbol: SQIcon {
        switch self {
        case .motion, .keying: .sparkles
        case .looks: .sequence
        case .voice: .microphone
        }
    }
}

extension QuickApplyCatalog {
    /// The palette rows of the Effects panel's own lists (effects, transitions, built-in presets) plus `presets`.
    @MainActor public static func items(presets: [PresetItem]) -> [QuickApplyItem] {
        items(effects: EffectsCatalog.catalog.map { ($0.id, $0.title) },
              builtInPresets: EffectsCatalog.builtInPresetEntries.map { ($0.id, $0.title) }, presets: presets)
    }
}
