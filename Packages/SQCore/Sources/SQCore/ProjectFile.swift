import Foundation

public enum ProjectFileError: Error, Equatable {
    case missing
    case corrupt
    case newerVersion(found: Int, supported: Int)
}

/// Package directory `Name.sqproj/` with `project.json` and `Autosave/`.
public enum ProjectFile {
    /// The project file extension, in one place. Older builds wrote `legacyFileExtensions`; those still open.
    public static let fileExtension = "sqproj"
    public static let legacyFileExtensions = ["ssproj"]

    public static func isProjectURL(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return e == fileExtension || legacyFileExtensions.contains(e)
    }
    public static func isLegacyURL(_ url: URL) -> Bool { legacyFileExtensions.contains(url.pathExtension.lowercased()) }

    /// The sibling `<name>.sqproj` a legacy project is saved to; `<name> 2.sqproj` etc. when that already exists.
    public static func convertedURL(for url: URL, fileManager fm: FileManager = .default) -> URL {
        let dir = url.deletingLastPathComponent(), name = url.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return candidate
    }

    /// v25 (W2.5 transitions pack): new `TransitionKind`s and optional `Transition.easing/direction/softness/motionBlur`.
    /// Identity step (no realMigrations line): old files decode with the kind defaults; a v24 build refuses v25 files
    /// rather than failing on an unknown transition kind.
    /// v26 (W4.1 format variants): `Timeline.variants`, `Clip.variantOverrides`; see ProjectFile+V26.swift.
    /// v27 (color grade as an effect): `Clip.color` effects become `ClipEffect`s of kind `color`; see ProjectFile+V27.swift.
    /// v28 (W7.1 effect transform stage): `ClipEffect` kinds `transform` and `reframe` (EffectTransformStage.swift).
    /// Identity step: older files have none; a v27 build refuses v28 files rather than silently dropping the stage.
    /// v29 (W7.5 user preset bake): optional `Clip.bakedEffects` (Convert to Keyframes records, UserPresetBake.swift).
    /// Identity step: older files have none; a v28 build refuses v29 files rather than dropping the records.
    /// v30 (W7.6 groups): optional `Timeline.group` and `ClipEffect` kind `groupTransform` (Grouping.swift). Identity step:
    /// older files have none; a v29 build refuses v30 files rather than showing groups as loose sequences.
    /// v31 (N4 two-style text): optional `TextStyle.secondLine` inside text payloads (SQText). Identity step: older
    /// files have none; a v30 build refuses v31 files rather than drawing a two-style title in one style.
    /// v32 (W6.7 masks): optional `Clip.masks` (Masks.swift). Identity step: older files have none; a v31 build refuses v32
    /// files rather than dropping the masks on save.
    /// v33 (W8.3 style kit): optional `Project.styleKit` (StyleKit.swift) and `TextStyle.tokens` inside text payloads (SQText).
    /// Identity step: older files have none; a v32 build refuses v33 files rather than dropping the brand on save.
    /// v34 (W9.3 input color spaces): `ColorSpaceID` cases pqBT2020, vLogVGamut, appleLog, dLogDGamut (clip footage
    /// override, media detection) and optional `Project.inputColorSpace`. Step: video media (not stills) whose stored
    /// detection is "rec709" loses it, so the app detects it again (pre-v34 builds stored rec709 for PQ files). A v33
    /// build refuses v34 files rather than failing on an unknown color space.
    /// v35 (H6 3/4 review fixes): the optional `Clip.pendingSourcePixelScale` (a v9 clip still owes its v10 Scale step)
    /// is version gated. Identity step. A file holding a pending clip is written as v35 so a v34 build refuses it rather
    /// than dropping the marker on save (its Scale would then never be converted); while v35 is the newest version, a
    /// file without pending clips is still written as v34 (`writtenVersion`), so older builds keep opening it.
    /// v36 (W9.7 stabilizer): `ClipEffect` kind `stabilize` (Stabilizer.swift). Identity step: older files have none; a v35
    /// build refuses v36 files rather than silently dropping the stage (the shot would play shaky and uncropped). From v36
    /// on every file is written as `currentVersion` (`writtenVersion`). v36 also writes `Keyframe` compactly (fields at
    /// their default are left out, read back as the default); full older keys decode unchanged. Only the project file
    /// does: presets and other payloads keep full keys, so older builds still read them.
    /// v37 (W9.8 subject masks): `ClipMask.source` `.subject` (person matte). Identity step. A file holding a subject mask
    /// is written as v37 so a v36 build refuses it (it would read the mask as a full-frame rectangle: an inverted or
    /// subtract mask hides the clip, and re-saving drops the source); while v37 is the newest version, a file without
    /// subject masks is still written as v36 (`writtenVersion`), so older builds keep opening it.
    /// v38 (N6b stinger): `TransitionKind.stinger` and the optional `Transition.stinger` (Stinger.swift). Identity step. A
    /// file holding a Stinger is written as v38 so a v37 build refuses it (it would fail on the unknown kind); others keep
    /// the lowest version that holds them (`writtenVersion`).
    /// v39 (AUDIO-FX): audio effects (`ClipEffect` kinds `audio.*`, AudioEffects.swift) on audio clips. Identity step. A file
    /// holding one is written as v39 so a v38 build refuses it (it would keep them but play the clip dry and list unknown
    /// effects); others keep the lowest version that holds them.
    /// v40 (FB-G): Motion's own Shutter Angle (`ClipAnimation.shutterAngle`, written only when open or keyed) and the element
    /// transitions (`TransitionKind.move`, `.zoom`, `.pop` with `Transition.params`). Identity step. A file holding either
    /// is written as v40 so a v39 build refuses it (it would fail on the unknown kind, or drop the shutter on save); others
    /// keep the lowest version that holds them.
    /// v41 (W9.6): Adjustment Layers (`GeneratorRef.adjustment`, AdjustmentClip.swift) and the blend modes beyond the v22 five
    /// (`BlendMode.isLegacy`). Identity step. A file holding either is written as v41 so a v40 build refuses it (it would draw
    /// the adjustment layer as an offline clip, or fail on the unknown blend mode); others keep the lowest version.
    /// v42 (GFX): Graphics clips (`GeneratorRef.graphics` with `Clip.graphics` layers, Graphics.swift). Identity step. A file
    /// holding one is written as v42 so a v41 build refuses it (it would drop the layers on save); others keep the lowest version.
    /// v43 (FB-B3 + N8b): Color Match reference (`ColorGradeData.match`), the project's live ducking setting
    /// (`Project.liveDucking`) and the per-track opt-out (`Track.isExcludedFromLiveDucking`). Identity step. A file holding
    /// any of them is written as v43 so a v42 build refuses it (it would drop them on save); others keep the lowest version.
    /// v44 (KEYFRAME-EASING, reverted on this branch): linked easing curves. This build no longer writes them; a v44+ file
    /// that holds `Project.easings` / `easeLink` fields still opens (the links were denormalised, every slot kept its shape
    /// in the old fields), the unknown keys are ignored and dropped on save. Identity step.
    /// v46 (AUDIO-FX-PRO): the `audio.multiband` and `audio.parametricEQ` clip effect kinds. Identity step (older files hold
    /// neither); a file holding one is written as v46 so a v45 build refuses it instead of silently dropping the effect.
    /// v45 (COLOR-GRADE-LINKS): linked grades (`Clip.gradeLink`) and range grades (`ClipEffect.colorRange`). Identity step:
    /// linked grades are denormalised, so older files have none and decode unchanged. A file holding either is written as v45
    /// so a v44 build refuses it (it would drop the links and render a range grade over the whole clip); others keep the
    /// lowest version.
    /// v47 (color target bar): `Clip.gradeIndependent` ("Linked" off in the Color panel). Identity step (older files
    /// have none); a file holding one is written as v47 so a v46 build refuses it (it would drop the switch and pull the
    /// clip back into its source's grade on the next edit).
    /// v48 (round 2 follow-ups): Color Range (`ColorGradeData.hslSecondary`, the HSL secondary qualifier and its
    /// correction). Identity step (older files have none); a file holding one is written as v48 so a v47 build refuses it
    /// (it would drop the range and its correction).
    /// v49 (adjustment follows the sequence end): `Clip.extendsToSequenceEnd` on an Adjustment Layer. Identity step (older
    /// files have none); a file holding one is written as v49 so a v48 build refuses it (it would drop the flag and leave
    /// the end of a grown cut ungraded).
    /// v50 (soft edges on range grades): `ClipEffect.colorFadeIn` / `colorFadeOut`. Identity step (older files have none); a
    /// file holding one is written as v50 so a v49 build refuses it (it would render the range with hard edges).
    /// v51 (Gradient effect): the `gradient` clip effect kind. Identity step (older files hold none); a file holding one is
    /// written as v51 so a v50 build refuses it (it would show the unknown kind as an inert effect and drop it on save).
    /// v52 (Stabilize as an effect): the Stabilizer's Method (`stabilizeMethod`, Standard | Gyroflow) and the Gyroflow
    /// settings (StabilizeEffect.swift). Identity step: a v51 Stabilizer has no Method and reads as Standard, its settings
    /// and keys unchanged. A file holding a Gyroflow Stabilizer is written as v52 so a v51 build refuses it (it would
    /// re-plan it as Standard and render the leftover keys); others keep the lowest version.
    /// v53 (transition layer): transition layers (`GeneratorRef.transitionLayer`, TransitionLayer.swift). Identity step (older
    /// files have none); a file holding one is written as v53 so a v52 build refuses it (it would draw the layer as an
    /// offline clip and transition nothing); others keep the lowest version.
    /// v54 (unified masks): Magic masks (`MaskSource.magic`, `ClipMask.magic`), masks that do not cut Opacity
    /// (`ClipMask.usedByOpacity` false) and effect mask inputs (`ClipEffect.maskInput`). Identity step (older files have
    /// none); a file holding one is written as v54 so a v53 build refuses it (it would cut the picture with masks meant
    /// for an effect and drop the inputs on save).
    /// v55 (blend parity): the rest of the standard blend set (Dissolve, Darker/Lighter Color, Vivid/Linear/Pin Light, Hard
    /// Mix, Subtract, Divide, Hue, Saturation, Color, Luminosity; `BlendMode.minimumFileVersion`). Identity step. A file
    /// holding one (clip or graphics layer) is written as v55 so a v54 build refuses it (it would fail on the unknown mode).
    /// v56 (gate for everything added since the v51 gradient gate that had none): the effect kinds Dynamic Zoom, Date Stamp,
    /// Posterize Time, Video Denoise, Deflicker, Motion Blur FX, Luma Key, Gate Weave, Scanlines, Chroma Bleed, Tracking Noise,
    /// audio De-Reverb / De-Hum / Low Cut / Dialogue Leveler; De-Esser options and Crop softness set away from their default;
    /// live ducking timing (`ProjectLiveDucking.timing`, `DuckTiming`) that is not classic. See ProjectFile+V56.swift.
    /// Identity step. A file holding any of them is written as v56 so a v55 build refuses it ("made with a newer version")
    /// instead of showing the effect as inert and dropping it on save; others keep the lowest version.
    /// v57 (bundles and subclips): `Clip.bundle` (Premiere's Clip > Group: clips tied for editing, Timeline+Bundle.swift) and
    /// `MediaRef.subclip` (Make Subclip, Subclip.swift). See ProjectFile+V57.swift. Identity step. A file holding either is
    /// written as v57 so a v56 build refuses it ("made with a newer version") instead of dropping them on save; others keep
    /// the lowest version.
    /// v58 (animation zones and title templates): `Clip.zones` and `Clip.templateSlots`. See ProjectFile+V58.swift. Identity
    /// step. A file holding either is written as v58 so a v57 build refuses it instead of dropping them on save; others keep
    /// the lowest version.
    /// v59 (Gyroflow lens and sync): a Gyroflow Stabilizer's Field of View, Lens Correction and Sync Offset
    /// (`GyroflowOptions`). See ProjectFile+V59.swift. Identity step. A file with one set away from its default is written
    /// as v59 so a v58 build refuses it instead of rendering a different picture; others keep the lowest version.
    /// v60 (clip markers): `Clip.markers` (source-time markers on a clip, ClipMarkers.swift). See ProjectFile+V60.swift.
    /// Identity step. A file holding any is written as v60 so a v59 build refuses it instead of dropping them on save;
    /// others keep the lowest version.
    /// v61 (Halftone, Tile, Kaleidoscope effect kinds): see ProjectFile+V61.swift. Identity step. A file using one is written
    /// as v61 so a v60 build refuses it instead of dropping the effect on save; others keep the lowest version.
    /// v62 (template fields on graphic layers): `TemplateSlot.graphicsLayer`, see ProjectFile+V62.swift. Identity step. A file
    /// holding a slot with it is written as v62 so a v61 build refuses it instead of dropping the field on save; others keep
    /// the lowest version.
    /// v63 (Follow on graphic layers): `GraphicsLayer.follow`, see ProjectFile+V63.swift. Identity step. A file holding one
    /// is written as v63 so a v62 build refuses it instead of drawing the follower elsewhere and dropping it on save; others
    /// keep the lowest version.
    /// v64 (Trails, Outline, Long Shadow effect kinds): see ProjectFile+V64.swift. Identity step. A file using one is written
    /// as v64 so a v63 build refuses it instead of dropping the effect on save; others keep the lowest version.
    /// v65 (Picture masks): `MaskSource.picture`, `ClipMask.pictureTrack` / `pictureChannel`, see ProjectFile+V65.swift.
    /// Identity step. A file holding one is written as v65 so a v64 build refuses it instead of dropping the link on save;
    /// others keep the lowest version.
    /// v66 (Sequence Volume): `Timeline.masterVolumeDB`, see ProjectFile+V66.swift. Identity step. A file with a sequence
    /// not at 0 dB is written as v66 so a v65 build refuses it instead of playing it at 0 dB and dropping the level on save;
    /// others keep the lowest version.
    /// v67 (Fast Cut): `Timeline.editMode` and `Clip.attachment`, see ProjectFile+V67.swift. Identity step. A file with a
    /// Fast Cut sequence or an attachment is written as v67 so a v66 build refuses it instead of opening it as Normal and
    /// dropping the attachments on save; Normal-only projects keep the lowest version (byte-identical).
    /// v68 (Canon Log input color spaces): nine `ColorSpaceID` cases, see ProjectFile+V68.swift. Identity step. A file that
    /// uses one is written as v68 so a v67 build refuses it instead of losing the input; others keep the lowest version.
    /// v69 (pixel aspect, F7.3): `VideoTrackInfo.pixelAspect` and `pixelAspectOverride`, see ProjectFile+V69.swift. Identity
    /// step. A file with non-square media is written as v69 so an older build refuses it instead of showing the picture
    /// squeezed and dropping the ratio on save; others keep the lowest version.
    /// v70 (audio channel routing, F7.10): `AudioTrackInfo.channelMap`, see ProjectFile+V70.swift. Identity step. A file with
    /// a chosen channel map is written as v70 so an older build refuses it instead of playing the file's layout and
    /// dropping the map on save; others keep the lowest version.
    /// v71 (Angles clip, F7.16): `Clip.angle` and `Timeline.angles`, see ProjectFile+V71.swift. Identity step. A file with
    /// an Angles clip or an Angles sequence is written as v71 so an older build refuses it instead of showing every angle
    /// stacked and dropping the choice on save; others keep the lowest version.
    /// v72 (one Look library, text concept B step 1): `StyleKit.looks` may hold Looks with payload version 2 (appearance
    /// without an animation, word highlight, caption segmentation), see ProjectFile+V72.swift. Identity step. A file with
    /// such a Look is written as v72 so an older build refuses it instead of drawing its captions in the default style;
    /// others keep the lowest version.
    /// v73 (Notch, audio effect `audio.notch`): see ProjectFile+V73.swift. Identity step. A file with a Notch is written as
    /// v73 so an older build refuses it instead of playing and exporting the clip with the tone still in; others keep the
    /// lowest version.
    /// v74 (item lanes, `GraphicsLayer.range`): see ProjectFile+V74.swift. Identity step. A file where an item of a Graphic
    /// has a range is written as v74 so an older build refuses it instead of drawing the item for the whole clip and
    /// dropping the range on save; others keep the lowest version.
    /// v75 (`CaptionWord.confidence`): see ProjectFile+V75.swift. Identity step. A file where a caption word carries a
    /// recognizer confidence is written as v75 so an older build refuses it instead of dropping the marks on save;
    /// others keep the lowest version.
    /// v76 (Graphic EQ `audio.graphicEQ`, Noise Gate `hold`): see ProjectFile+V76.swift. Identity step. A file with a Graphic EQ,
    /// or a Noise Gate with a Hold above 0, is written as v76 so an older build refuses it instead of playing the clip without
    /// the EQ or with a gate that closes too early; others keep the lowest version.
    /// v77 (`Interpolation.holdAhead`, Hold Ahead): see ProjectFile+V77.swift. Identity step: the two-key form older files
    /// wrote for it is folded where a track is decoded. A file with a Hold Ahead key is written as v77 so an older build
    /// refuses it instead of failing on the unknown case; others keep the lowest version.
    /// v78 (Pro grade, effect kind `colorGraph` with `ClipEffect.colorGraph`): see ProjectFile+V78.swift. Identity step.
    /// A file with a Color Graph effect is written as v78 so an older build refuses it instead of dropping the Pro grade
    /// on save; others keep the lowest version.
    /// v79 (Parallel and Layer Steps, Step Mix): see ProjectFile+V79.swift. Identity step. A file with such a Step is written
    /// as v79 so an older build refuses it instead of showing the graph as plain serial Steps; others keep the lowest version.
    /// v80 (explicit Steps wiring and key wires): see ProjectFile+V80.swift. Identity step. A graph with custom wiring or a key
    /// wire is written as v80 so an older build refuses it instead of ignoring the wires; others keep the lowest version.
    /// v81 (sequence timecode start / display, preview quality): see ProjectFile+V81.swift. Identity step. A file with any of them
    /// is written as v81 so an older build refuses it instead of dropping them; others keep the lowest version.
    /// v82 (sequence channel layout, sequence pixel shape): see ProjectFile+V82.swift. Identity step; each is written only when not the default.
    /// v83 (project notes): see ProjectFile+V83.swift. Identity step; written only when the notes are not empty.
    /// v84 (perspective tilt): `ClipAnimation.tiltX` / `tiltY` (PerspectiveTilt.swift), written only when set or keyed. See
    /// ProjectFile+V84.swift. Identity step. A file holding one is written as v84 so a v83 build refuses it instead of
    /// dropping the tilt on save; others keep the lowest version.
    /// v85 (per-edge Follow padding): `GraphicsFollow.edgePadding`, written only when the four paddings differ. See
    /// ProjectFile+V85.swift. Identity step; a file holding one is written as v85 so a v84 build refuses it instead of
    /// drawing the follower with one padding and dropping the rest on save.
    /// v86 (keyable Sequence Volume): `Timeline.masterVolumeKeys`, written only when keyed. See ProjectFile+V86.swift.
    /// Identity step; a file holding keys is written as v86 so a v85 build refuses it instead of playing the static level.
    /// v87 (Color range masks): `MaskSource.colorRange` with `ClipMask.colorRange`. See ProjectFile+V87.swift. Identity step;
    /// a file holding one is written as v87 so a v86 build refuses it instead of reading a full-frame path mask.
    /// v88 (source patch per sequence): `Timeline.sourcePatch`, written only when not the default. See ProjectFile+V88.swift.
    /// Identity step; a file holding one is written as v88 so a v87 build refuses it instead of dropping the patch on save.
    /// v89 (reversed transitions): `Transition.reversed`, `TransitionLayer.reversed`, written only when true. See
    /// ProjectFile+V89.swift. Identity step; a file holding one is written as v89 so a v88 build refuses it.
    /// v90 (Track Mask effect): effect kind `trackMask` with `ClipEffect.maskTrack`. See ProjectFile+V90.swift. Identity step;
    /// a file holding one is written as v90 so a v89 build refuses it instead of showing an inert effect and dropping it on save.
    /// v93 (log mode, target space, HDR conform): `ClipFootageColor.logMode/targetSpace/hdrConform`, written only when non-default. See ProjectFile+V93.swift. Identity step.
    /// v92 (Anti-flicker Filter): `ClipAnimation.antiFlicker`, written only when above 0 or keyed. See ProjectFile+V92.swift.
    /// Identity step; a file holding one is written as v92 so a v91 build refuses it instead of dropping the filter on save.
    /// v94 (Zone Board, color-volume mask): `ColorGradeData.zoneBoard` and `HSLSecondary.maskMode`, written only when set. See ProjectFile+V94.swift. Identity step.
    public static let currentVersion = 94
    /// The version that introduced the gate for `Clip.pendingSourcePixelScale`.
    static let pendingScaleVersion = 35
    /// The version that introduced the `stabilize` effect kind.
    static let stabilizeVersion = 36
    /// The version that introduced subject masks (`MaskSource.subject`).
    static let subjectMaskVersion = 37
    /// The version that introduced Stinger transitions.
    static let stingerVersion = 38
    /// The version that introduced clip audio effects.
    static let audioEffectsVersion = 39
    /// The version that introduced Motion's Shutter Angle and element transitions (FB-G).
    static let motionShutterVersion = 40
    static let elementTransitionVersion = 40
    /// The version that introduced Adjustment Layers and the extended blend modes (W9.6).
    static let adjustmentVersion = 41
    static let extendedBlendVersion = 41
    /// The version that introduced Graphics clips (GFX).
    static let graphicsVersion = 42
    /// The version that introduced Color Match references and the stored live ducking settings.
    static let colorMatchVersion = 43
    static let liveDuckingSettingsVersion = 43
    /// The version that introduced linked grades and range grades (COLOR-GRADE-LINKS).
    static let gradeLinkVersion = 45
    /// The version that introduced the Multiband Compressor and 5-band Parametric EQ audio effects (AUDIO-FX-PRO).
    static let voiceChainVersion = 46
    /// The version that introduced the per-clip "Linked" switch of the Color target bar.
    static let independentGradeVersion = 47
    /// The version that introduced Color Range (HSL secondary) data.
    static let colorRangeVersion = 48
    /// The version that introduced `Clip.extendsToSequenceEnd`.
    static let extendAdjustmentVersion = 49
    /// The version that introduced range grade fades.
    static let rangeFadeVersion = 50
    /// The version that introduced the `gradient` effect kind.
    static let gradientEffectVersion = 51
    /// The version that introduced the Stabilizer's Method (Gyroflow).
    static let gyroflowStabilizeVersion = 52
    /// The version that introduced transition layers.
    static let transitionLayerVersion = 53
    /// The version that introduced Magic masks and effect mask inputs.
    static let maskInputVersion = 54
    /// The version that completed the standard blend set.
    static let fullBlendVersion = 55
    /// The version that gates the effect kinds and options listed at `currentVersion`'s v56 note.
    static let v56Version = 56
    /// The version that introduced bundles and subclips.
    static let v57Version = 57
    /// The version that introduced animation zones and title templates.
    static let v58Version = 58
    /// The version that introduced the Gyroflow Field of View, Lens Correction and Sync Offset.
    static let v59Version = 59
    /// The version that introduced clip markers.
    static let v60Version = 60
    /// The version that gates the Halftone, Tile and Kaleidoscope effect kinds.
    static let v61Version = 61
    /// The version that introduced template fields on graphic layers.
    static let v62Version = 62
    /// The version that introduced Follow on graphic layers.
    static let v63Version = 63
    /// The version that gates the Trails, Outline and Long Shadow effect kinds.
    static let v64Version = 64
    /// The version that introduced Picture masks.
    static let v65Version = 65
    /// The version that introduced Sequence Volume.
    static let v66Version = 66
    /// The version that introduced Fast Cut (edit mode and clip attachments).
    static let v67Version = 67
    /// The version that introduced the Canon Log input color spaces.
    static let v68Version = 68
    /// The version that introduced pixel aspect ratios on media.
    static let v69Version = 69
    /// The version that introduced audio channel maps on media.
    static let v70Version = 70
    /// The version that introduced Angles clips.
    static let v71Version = 71
    /// The version that introduced Look payloads newer than the caption look (payload version 1).
    static let v72Version = 72
    /// The version that introduced the Notch audio effect.
    static let v73Version = 73
    /// The version that introduced item ranges in a Graphic.
    static let v74Version = 74
    /// The version that introduced the confidence of a caption word.
    static let v75Version = 75
    /// The version that introduced the Graphic EQ and the Noise Gate hold.
    static let v76Version = 76
    /// The version that introduced Hold Ahead keys. Not part of `writtenVersion(for:)`: the keys say so while they are
    /// written (`HoldAheadSeen`).
    static let v77Version = 77
    /// The version that introduced the Pro grade (Color Graph effect).
    static let v78Version = 78
    /// The version that introduced Parallel and Layer Steps and the Step Mix.
    static let v79Version = 79
    /// The version that introduced explicit Steps wiring and key wires.
    static let v80Version = 80
    static let v81Version = 81
    static let v82Version = 82
    static let v83Version = 83
    /// The version that introduced the perspective tilt. Not part of `writtenVersion(for:)`: the animation says so while it
    /// is written (`TiltSeen`).
    static let v84Version = 84
    /// The version that introduced per-edge Follow padding (gated like v84, by `FollowEdgePaddingSeen`).
    static let v85Version = 85
    /// The version that introduced the keyable Sequence Volume (content gate: `Project.containsV86Content`).
    static let v86Version = 86
    /// The version that introduced Color range masks (content gate: `Project.containsV87Content`).
    static let v87Version = 87
    /// The version that introduced the saved source patch (content gate: `Project.containsV88Content`).
    static let v88Version = 88
    /// The version that introduced reversed transitions (content gate: `Project.containsV89Content`).
    static let v89Version = 89
    /// The version that introduced the Track Mask effect (content gate: `Project.containsV90Content`).
    static let v90Version = 90
    /// The version that introduced the saved Snapping / Linked Selection toggles (content gate: `Project.containsV91Content`).
    static let v91Version = 91
    /// The version that introduced Motion's Anti-flicker Filter (content gate: `Project.containsV92Content`).
    static let v92Version = 92
    /// The version that introduced per-clip log mode, target space and HDR conform switch (content gate: `Project.containsV93Content`).
    static let v93Version = 93
    /// The version that introduced the Zone Board and the color-volume mask (content gate: `Project.containsV94Content`).
    static let v94Version = 94

    /// The version a project is written with: the lowest one that can hold its content, so older builds keep opening it.
    /// v36 is the floor (every file since W9.7 writes compact keyframes).
    static func writtenVersion(for p: Project) -> Int {
        if p.containsV94Content { return v94Version }
        if p.containsV93Content { return v93Version }
        if p.containsV92Content { return v92Version }
        if p.containsV91Content { return v91Version }
        if p.containsV90Content { return v90Version }
        if p.containsV89Content { return v89Version }
        if p.containsV88Content { return v88Version }
        if p.containsV87Content { return v87Version }
        if p.containsV86Content { return v86Version }
        if p.containsV83Content { return v83Version }
        if p.containsV82Content { return v82Version }
        if p.containsV81Content { return v81Version }
        if p.containsV80Content { return v80Version }
        if p.containsV79Content { return v79Version }
        if p.containsV78Content { return v78Version }
        if p.containsV76Content { return v76Version }
        if p.containsV75Content { return v75Version }
        if p.containsV74Content { return v74Version }
        if p.containsV73Content { return v73Version }
        if p.containsV72Content { return v72Version }
        if p.containsV71Content { return v71Version }
        if p.containsV70Content { return v70Version }
        if p.containsV69Content { return v69Version }
        if p.containsV68Content { return v68Version }
        if p.containsV67Content { return v67Version }
        if p.containsV66Content { return v66Version }
        if p.containsV65Content { return v65Version }
        if p.containsV64Content { return v64Version }
        if p.containsV63Content { return v63Version }
        if p.containsV62Content { return v62Version }
        if p.containsV61Content { return v61Version }
        if p.containsV60Content { return v60Version }
        if p.containsV59Content { return v59Version }
        if p.containsV58Content { return v58Version }
        if p.containsV57Content { return v57Version }
        if p.containsV56Content { return v56Version }
        if p.containsFullBlendModes { return fullBlendVersion }
        if p.containsMaskInputs { return maskInputVersion }
        if p.containsTransitionLayers { return transitionLayerVersion }
        if p.containsGyroflowStabilizers { return gyroflowStabilizeVersion }
        if p.containsGradientEffects { return gradientEffectVersion }
        if p.containsRangeFades { return rangeFadeVersion }
        if p.containsExtendedAdjustments { return extendAdjustmentVersion }
        if p.containsColorRangeQualifiers { return colorRangeVersion }
        if p.containsIndependentGrades { return independentGradeVersion }
        if p.containsVoiceChainEffects { return voiceChainVersion }
        if p.containsGradeLinksOrRanges { return gradeLinkVersion }
        if p.containsColorMatch || p.containsLiveDuckingSettings { return colorMatchVersion }
        if p.containsGraphicsClips { return graphicsVersion }
        if p.containsAdjustmentClips || p.containsExtendedBlendModes { return adjustmentVersion }
        if p.containsMotionShutter || p.containsElementTransitions { return motionShutterVersion }
        if p.containsAudioEffects { return audioEffectsVersion }
        if p.containsStinger { return stingerVersion }
        if p.containsSubjectMask { return subjectMaskVersion }
        return stabilizeVersion
    }
    public typealias JSONObject = [String: Any]
    /// Upgrades the top-level object from version N to N+1, keyed by N.
    public typealias Migrations = [Int: (JSONObject) throws -> JSONObject]
    /// Steps that change data. One entry per version, one line each, so streams that merge out of order never
    /// collide on a line or on a key. A version without an entry here is an identity step (see `migrations`).
    static var realMigrations: Migrations {
        var t: Migrations = [:]
        t[1] = migrateV1toV2
        t[2] = migrateV2toV3
        t[3] = migrateV3toV4
        t[4] = migrateV4toV5
        t[5] = migrateV5toV6
        t[6] = migrateV6toV7
        t[7] = migrateV7toV8
        t[8] = migrateV8toV9
        t[9] = migrateV9toV10
        t[10] = migrateV10toV11
        t[11] = migrateV11toV12
        t[12] = migrateV12toV13
        t[13] = migrateV13toV14
        t[14] = migrateV14toV15
        t[15] = migrateV15toV16
        t[16] = migrateV16toV17
        t[17] = migrateV17toV18
        t[18] = migrateV18toV19
        t[19] = migrateV19toV20
        t[20] = migrateV20toV21
        t[21] = migrateV21toV22
        t[22] = migrateV22toV23
        t[23] = migrateV23toV24
        t[25] = migrateV25toV26
        t[26] = migrateV26toV27
        t[33] = migrateV33toV34
        t[37] = migrateV37toV38
        t[38] = migrateV38toV39
        t[40] = migrateV40toV41
        t[41] = migrateV41toV42
        t[42] = migrateV42toV43
        t[47] = migrateV47toV48
        t[48] = migrateV48toV49
        t[49] = { $0 }   // v50: range grade fades only add optional effect fields
        t[50] = { $0 }   // v51: the gradient effect kind only adds an effect kind
        t[51] = { $0 }   // v52: the Stabilizer's Method; a missing one reads as Standard
        t[52] = { $0 }   // v53: transition layers are generator clips with a new kind
        t[53] = { $0 }   // v54: Magic masks and effect mask inputs only add optional fields
        t[54] = { $0 }   // v55: the full blend set only adds enum values
        t[55] = { $0 }   // v56: effect kinds and optional parameters only
        t[56] = { $0 }   // v57: bundles and subclips only add optional fields
        return t
    }
    /// The full chain 1..<currentVersion. Missing steps are identity: every format change since v2 only added
    /// fields that are optional on decode.
    public static var migrations: Migrations {
        var t = realMigrations
        for v in 1..<currentVersion where t[v] == nil { t[v] = { $0 } }
        return t
    }

    /// v34: forget a stored Rec.709 detection of video media (not stills) so `MediaInfo.needsColorDetection` reruns
    /// detection on open: v33 builds stored "rec709" for PQ (HDR10) files and for every untagged file alike.
    /// v38: Stinger transitions only add a kind and an optional field; older files have none.
    static func migrateV37toV38(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v39: audio effects only add effect kinds; older files have none.
    static func migrateV38toV39(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v41: Adjustment Layers and the extended blend modes only add a generator kind and enum cases; older files have none.
    static func migrateV40toV41(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v42: Graphics clips only add a generator kind and an optional clip field; older files have none.
    static func migrateV41toV42(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v43: Color Match and live ducking settings only add optional fields; older files have none.
    static func migrateV42toV43(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v48: Color Range only adds an optional grade field; older files have none.
    static func migrateV47toV48(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v49: the extend-to-sequence-end flag only adds an optional clip field; older files have none.
    static func migrateV48toV49(_ obj: JSONObject) throws -> JSONObject { obj }

    static func migrateV33toV34(_ obj: JSONObject) throws -> JSONObject {
        guard var p = obj["project"] as? JSONObject, let media = p["media"] as? [Any] else { return obj }
        p["media"] = media.map { item -> Any in
            guard var m = item as? JSONObject, var info = m["info"] as? JSONObject,
                  info["video"] != nil, (info["isStill"] as? Bool) != true,
                  info["detectedColorSpace"] as? String == ColorSpaceID.rec709.rawValue else { return item }
            info.removeValue(forKey: "detectedColorSpace")
            m["info"] = info
            return m
        }
        var o = obj
        o["project"] = p
        return o
    }

    /// v2: `Timeline.frameDuration` moved into `Timeline.format` (defaults 1920x1080, 48 kHz).
    /// Track flags, `inOut` and `markers` are optional on decode, so nothing else changes.
    static func migrateV1toV2(_ obj: JSONObject) throws -> JSONObject {
        var o = obj
        guard var p = o["project"] as? JSONObject else { throw ProjectFileError.corrupt }
        let timelines = (p["timelines"] as? [Any] ?? []).map { item -> Any in
            guard var t = item as? JSONObject, let fd = t.removeValue(forKey: "frameDuration") else { return item }
            t["format"] = ["width": 1920, "height": 1080, "frameDuration": fd, "audioSampleRate": 48_000] as JSONObject
            return t
        }
        if p["timelines"] != nil { p["timelines"] = timelines }
        o["project"] = p
        return o
    }

    /// v3: clips gain `animation` (animatable transform, opacity and volume with static fallbacks).
    /// A v2 clip has no animation key; `Clip` decodes that as all-default static properties and no keyframes,
    /// so the object passes through unchanged.
    static func migrateV2toV3(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v4: `Project.rootBin` and `Project.sourceMarks`. Both are optional on decode: a v3 project gets all media
    /// and timelines in the root bin and no marks, so the object passes through unchanged.
    static func migrateV3toV4(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v5: `Clip.sequence` (nested sequences), `Timeline.captionTracks`, `ClipAnimation.cornerRadius`. All optional on
    /// decode with neutral defaults (no nesting, no caption tracks, radius 0): identity migration.
    static func migrateV4toV5(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v6: `Clip.generator` (text layers and other generator clips). Optional on decode, absent = media or nested
    /// clip: identity migration.
    static func migrateV5toV6(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v7: `Clip.color` (per-clip color: source override, correction, LUTs) and `MediaInfo.detectedColorSpace` /
    /// `embeddedLUTName`. All optional on decode; absent = defaults (automatic from media, neutral): identity migration.
    static func migrateV6toV7(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v8: `label` (LabelColor) on `MediaRef`, `Timeline` and `Clip`. Optional on decode; nil = default for the type:
    /// identity migration.
    static func migrateV7toV8(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v9: `Clip.effects` (explicitly applied effects). `ClipAnimation.cornerRadius` is gone: `Clip` decoding turns a
    /// non-default radius into an applied Rounded Corners effect and drops a default one (= not applied).
    static func migrateV8toV9(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v10: Scale is relative to the picture's own pixels (100 % = one source pixel per sequence pixel) instead of the
    /// aspect-fitted picture; `Clip.isStill`, `MediaInfo.isStill`, `VideoTrackInfo.rotation` are optional on decode.
    /// Every picture clip's Scale is multiplied by its fit scale (`Project.migrateScaleToSourcePixels`) so nothing moves
    /// on screen. A clip whose media has no probe info is marked `Clip.pendingSourcePixelScale` and converted when the
    /// info arrives (`Project.applyPendingScaleMigration`). A project that does not decode is passed on unchanged (the
    /// final decode then reports it).
    static func migrateV9toV10(_ obj: JSONObject) throws -> JSONObject {
        var o = obj
        guard let projectObj = obj["project"], JSONSerialization.isValidJSONObject(projectObj),
              let raw = try? JSONSerialization.data(withJSONObject: projectObj),
              var project = try? decoder().decode(Project.self, from: raw) else { return obj }
        project.migrateScaleToSourcePixels()
        guard let data = try? encoder().encode(project),
              let migrated = try? JSONSerialization.jsonObject(with: data) else { return obj }
        o["project"] = migrated
        return o
    }

    /// v11: `Clip.color` is an ordered list of color blocks (Lumetri-like). `ClipColor` decoding maps the v10 single
    /// correction / conversion LUT / creative LUT fields into blocks in the old order: identity on the JSON object.
    static func migrateV10toV11(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v12: `Clip.color` holds Color effects with fixed sections (`ClipColor.effects`) instead of the block list.
    /// `ClipColor` decoding maps v11 `sections` (first block of each kind into the first effect, extras into further
    /// effects): identity on the JSON object.
    static func migrateV11toV12(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v13: markers gain color, comment and duration (decoded with defaults).
    static func migrateV12toV13(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v14: `ColorEffect.hueCurves` (Hue vs Sat, Hue vs Hue, Hue vs Luma, Luma vs Sat, Sat vs Sat). A missing key decodes as flat
    /// (neutral) curves: identity on the JSON object.
    static func migrateV13toV14(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v15: `Clip.speed` (ratio), `Clip.reversed`, `Clip.keepsPitch`. All optional on decode; absent = 100 %, not reversed,
    /// pitch kept: identity migration.
    static func migrateV14toV15(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v16: `Clip.audioGainDB` (Audio Gain), `TextStyle.tracking/italic/verticalAlignment`, `TextTemplate.box` (area text) and
    /// `TextShadow.restingAngle` (inside text payloads), `CaptionPreset.gap`. All optional on decode; absent = no gain,
    /// no tracking, upright, point text, no gap: identity migration. Older builds drop these fields on save.
    static func migrateV15toV16(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v20 (audio-shortform): `Track.volumeDB` / `Track.pan`, `Clip.audioTag`, `Clip.duckKeyIDs`. All optional on decode;
    /// absent = 0 dB, center, untagged, no generated keys: identity migration. Older builds drop these fields on save.
    /// 
    static func migrateV19toV20(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v17: `Track.transitions` (cut and fade transitions). Optional on decode; absent = none: identity migration.
    /// Older builds drop the transitions on save.
    static func migrateV16toV17(_ obj: JSONObject) throws -> JSONObject { obj }


    /// v18 (round 2, timeline-edit): `Clip.isEnabled` (Enable / Disable Clip). Optional on decode; absent = enabled:
    /// identity migration. (v17 belongs to transitions; `currentVersion` is raised to the highest number on merge.)
    static func migrateV17toV18(_ obj: JSONObject) throws -> JSONObject { obj }
    /// v21 (stream captions-text; v17-v20 belong to the other round-2 streams): `CaptionTrack.styleRef/animationRef/karaoke`,
    /// `CaptionItem.styleOverridden/words`, `TextStyle.allCaps`, `TextStroke.position`, `TextTemplate.highlight` (inside
    /// text payloads). All optional on decode; absent = captions keep their own style, no word highlight, no overrides,
    /// normal case, outside stroke: identity migration. Older builds drop these fields on save.
    static func migrateV20toV21(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v22 (effects-look): `Clip.blendMode` (Opacity > Blend Mode), `Clip.holdFrame` (Frame Hold) and the fx toggles
    /// `Clip.motionEnabled` / `opacityEnabled`. Effect instances need no new field (`ClipEffect` always had an id; the list
    /// order is the evaluation order). All optional on decode; absent = Normal, no hold, toggles on: identity migration.
    static func migrateV21toV22(_ obj: JSONObject) throws -> JSONObject { obj }

    /// v23 (stream speed-time): `Clip.speedKeys` (time remapping: segments with ramps and an origin) and
    /// `Clip.timeInterpolation`. Both optional on decode; absent = constant speed (`speed` / `reversed`) and frame sampling,
    /// so every v22 clip, constant-speed clips included, decodes and plays unchanged: identity migration. Older builds drop the
    /// speed track on save and then play the clip at its `speed` over its `source` hull.
    static func migrateV22toV23(_ obj: JSONObject) throws -> JSONObject { obj }


    static let fileName = "project.json"
    static let autosaveDir = "Autosave"

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        e.userInfo[HoldAheadSeen.key] = HoldAheadSeen()   // v77 gate, one per encoder
        e.userInfo[TiltSeen.key] = TiltSeen()   // v84 gate, one per encoder
        e.userInfo[FollowEdgePaddingSeen.key] = FollowEdgePaddingSeen()   // v85 gate, one per encoder
        e.userInfo[Keyframe<Double>.compactCodingKey] = true   // v36: project files only (see `Keyframe`)
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return d
    }

    /// `appFormat` is the writing build's `currentVersion` (additive and optional; no format bump). It tells a file saved by
    /// an older build from one this build merely wrote at a lower, content-gated `formatVersion`.
    private struct Envelope: Encodable {
        var appFormat: Int; var formatVersion: Int; var project: Project
        enum CodingKeys: String, CodingKey { case appFormat, formatVersion, project }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(appFormat, forKey: .appFormat)
            try c.encode(project, forKey: .project)   // first: its keys mark a Hold Ahead while they are written
            let ahead = (encoder.userInfo[HoldAheadSeen.key] as? HoldAheadSeen)?.value ?? false
            let tilt = (encoder.userInfo[TiltSeen.key] as? TiltSeen)?.value ?? false
            let base = ahead ? max(formatVersion, ProjectFile.v77Version) : formatVersion
            let pad = (encoder.userInfo[FollowEdgePaddingSeen.key] as? FollowEdgePaddingSeen)?.value ?? false
            let v84 = tilt ? max(base, ProjectFile.v84Version) : base
            try c.encode(pad ? max(v84, ProjectFile.v85Version) : v84, forKey: .formatVersion)
        }
    }

    static func encode(_ project: Project) throws -> Data {
        var p = project
        p.pruneUnusedGroups()   // W7.6: no hidden group sequence outlives the clips that played it
        return try encoder().encode(Envelope(appFormat: currentVersion, formatVersion: writtenVersion(for: p), project: p))
    }

    /// Every migration step from this version on is identity (formats since v34 only add fields optional on decode), so a
    /// file at this version or later decodes straight from its bytes. A real migration at or after it must raise this.
    static let identityMigrationsFrom = 34

    /// The project of a file whose remaining migrations are all identity, decoded in one pass; nil for anything else (an
    /// older or newer version, or contents the migration path must judge).
    static func decodeDirect(_ data: Data) -> Project? {
        struct Direct: Decodable {
            var project: Project?
            enum CodingKeys: String, CodingKey { case formatVersion, project }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let v = try c.decode(Int.self, forKey: .formatVersion)
                project = (ProjectFile.identityMigrationsFrom...ProjectFile.currentVersion).contains(v) ? try c.decode(Project.self, forKey: .project) : nil
            }
        }
        return (try? decoder().decode(Direct.self, from: data))?.project
    }

    /// Decodes file contents, running migrations from older versions. `nil` = the standard chain (`migrations`), which
    /// lets a file needing no real migration skip the JSON rewrite (`decodeDirect`).
    static func decode(_ data: Data, migrations: Migrations?) throws -> Project {
        if migrations == nil, let p = decodeDirect(data) { return p }
        let migrations = migrations ?? Self.migrations
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              var version = obj["formatVersion"] as? Int, obj["project"] != nil else { throw ProjectFileError.corrupt }
        if version > currentVersion { throw ProjectFileError.newerVersion(found: version, supported: currentVersion) }
        while version < currentVersion {
            guard let step = migrations[version] else { throw ProjectFileError.corrupt }
            obj = try step(obj)
            version += 1
        }
        // `data(withJSONObject:)` raises (not throws) for a non-container value such as `"project": 5`.
        guard let projectObj = obj["project"], JSONSerialization.isValidJSONObject(projectObj),
              let raw = try? JSONSerialization.data(withJSONObject: projectObj),
              let project = try? decoder().decode(Project.self, from: raw) else { throw ProjectFileError.corrupt }
        return project
    }

    public static func write(_ project: Project, to url: URL, fileManager fm: FileManager = .default) throws {
        let data = try encode(project)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try backupIfOlder(url.appendingPathComponent(fileName), for: url, fileManager: fm)
        try atomicWrite(data, to: url.appendingPathComponent(fileName), fileManager: fm)
    }

    /// Files without `appFormat` below this were provably written by an older build (the lowest version any build
    /// writes is 36); from 36 on they are unknown and never backed up.
    static let unknownAuthorFloor = 36

    /// `(appFormat, formatVersion)` from the first bytes of a project file (keys are sorted, so both come first).
    static func header(of file: URL) -> (app: Int?, version: Int)? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 256), case let text = String(decoding: d, as: UTF8.self) else { return nil }
        func int(_ key: String) -> Int? {
            guard let r = text.range(of: "\"\(key)\"") else { return nil }
            let rest = text[r.upperBound...].drop { $0 == " " || $0 == ":" }
            return Int(rest.prefix { $0.isNumber })
        }
        return int("formatVersion").map { (int("appFormat"), $0) }
    }

    /// Before a save by a newer build overwrites a file an older build wrote, copies it to `<package>.v<oldVersion>.bak`
    /// beside the package (once, never overwritten) and keeps the 3 highest-version backups. Saves of a file this build
    /// wrote make none. A failed backup stops the save.
    static func backupIfOlder(_ old: URL, for package: URL, fileManager fm: FileManager) throws {
        guard let (app, v0) = header(of: old) else { return }
        let newer = (app ?? 0) > currentVersion || v0 > currentVersion   // a newer build's file: never overwrite unbacked
        guard newer || (app.map({ $0 < currentVersion }) ?? (v0 < unknownAuthorFloor)) else { return }
        let v = newer ? max(app ?? 0, v0) : v0
        let dir = package.deletingLastPathComponent(), prefix = package.lastPathComponent + ".v"
        let bak = dir.appendingPathComponent("\(prefix)\(v).bak")
        if !fm.fileExists(atPath: bak.path) { try fm.copyItem(at: old, to: bak) }
        let baks = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "bak" && $0.lastPathComponent != bak.lastPathComponent }
            .compactMap { u -> (URL, Int)? in
                let n = u.deletingPathExtension().lastPathComponent.dropFirst(package.lastPathComponent.count + 2)
                return Int(n).map { (u, $0) }
            }.sorted { $0.1 > $1.1 }
        for (u, _) in baks.dropFirst(2) { try? fm.removeItem(at: u) }
    }

    public static func read(from url: URL, migrations: Migrations? = nil) throws -> Project {
        try readFile(url.appendingPathComponent(fileName), migrations: migrations)
    }

    static func readFile(_ file: URL, migrations: Migrations?) throws -> Project {
        guard FileManager.default.fileExists(atPath: file.path) else { throw ProjectFileError.missing }
        guard let data = try? Data(contentsOf: file) else { throw ProjectFileError.corrupt }
        return try decode(data, migrations: migrations)
    }

    /// Writes to a temp file next to `file`, then replaces it. The old file survives a failed write.
    static func atomicWrite(_ data: Data, to file: URL, fileManager fm: FileManager,
                            beforeRename: (() throws -> Void)? = nil) throws {
        let dir = file.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        flush(tmp)   // contents on disk before the rename can make them visible
        do {
            try beforeRename?()
            try FileReplace.replace(file, withItemAt: tmp, fileManager: fm)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        flush(dir)   // the rename itself survives a power loss
    }

    /// fsync (F_FULLFSYNC where available) of a file or directory; best effort.
    private static func flush(_ url: URL) {
        #if os(Windows)
        // Directories cannot be opened for writing on Windows; the file sync is all we can do there.
        if let handle = try? FileHandle(forWritingTo: url) { try? handle.synchronize(); try? handle.close() }
        #else
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        #if canImport(Darwin)
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        #endif
        _ = fsync(fd)
        #endif
    }

    // MARK: Autosave

    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.date(from: s)
    }

    /// Writes `Autosave/<yyyyMMdd-HHmmss-SSS>.json` (UTC) and keeps only the newest `keep` snapshots.
    @discardableResult
    public static func autosave(_ project: Project, in url: URL, keep: Int = 10, date: Date = Date(),
                                fileManager fm: FileManager = .default) throws -> URL {
        let dir = url.appendingPathComponent(autosaveDir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // A clock set back must not sort the new snapshot below the older ones (it would be pruned and never "latest"):
        // the name is at least 1 ms after the newest existing snapshot.
        var stamp = date
        if let last = autosaves(in: url, fileManager: fm).last,
           let t = parseTimestamp(last.deletingPathExtension().lastPathComponent), t >= date {
            stamp = t.addingTimeInterval(0.001)
        }
        let file = dir.appendingPathComponent(timestamp(stamp) + ".json")
        try atomicWrite(try encode(project), to: file, fileManager: fm)
        let all = autosaves(in: url, fileManager: fm)
        for old in all.dropLast(max(keep, 1)) where old != file { try? fm.removeItem(at: old) }
        return file
    }

    /// Snapshots, oldest first (names sort chronologically).
    public static func autosaves(in url: URL, fileManager fm: FileManager = .default) -> [URL] {
        let dir = url.appendingPathComponent(autosaveDir)
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func latestAutosave(in url: URL, migrations: Migrations? = nil,
                                      fileManager fm: FileManager = .default) -> Project? {
        for f in autosaves(in: url, fileManager: fm).reversed() {
            if let p = try? readFile(f, migrations: migrations) { return p }
        }
        return nil
    }
}
