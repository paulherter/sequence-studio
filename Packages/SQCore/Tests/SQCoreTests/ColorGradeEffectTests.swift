import Foundation
import Testing
@testable import SQCore

/// v27: the color grade is a `ClipEffect` of kind `color` (one per Color effect, stacked like Lumetri Color); `Clip.color`
/// is a view on those effects plus the footage interpretation.
@Suite struct ColorGradeEffectTests {
    static let fd = Time(1, 25)

    static func picture(media: UUID = UUID()) -> Clip {
        Clip(name: "v", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
             start: .zero, mediaDuration: Time(10, 1))
    }

    /// A grade that touches every field of two Color effects (LUT refs of every kind, curves, toggles).
    static func richGrade(media: UUID) -> ClipColor {
        var c = ClipColor(source: .sLog3SGamut3Cine, useEmbeddedLUT: false)
        c.effects[0].basic.temperature = 12.5; c.effects[0].basic.tint = -3; c.effects[0].basic.exposure = 1.25
        c.effects[0].basic.contrast = 20; c.effects[0].basic.highlights = -40; c.effects[0].basic.shadows = 15
        c.effects[0].basic.whites = 5; c.effects[0].basic.blacks = -7; c.effects[0].basic.saturation = 130
        c.effects[0].basic.vibrance = 9
        c.effects[0].inputLUT = .embedded(media)
        c.effects[0].creative.look = .file("/luts/look.cube"); c.effects[0].creative.intensity = 60
        c.effects[0].creative.fadedFilm = 11; c.effects[0].creative.vibrance = -4; c.effects[0].creative.saturation = 90
        c.effects[0].creative.shadowTint = WheelValue(hue: 200, amount: 0.3)
        c.effects[0].creative.highlightTint = WheelValue(hue: 35.5, amount: 0.125)
        c.effects[0].creative.tintBalance = -20
        c.effects[0].curves.master = [CurvePoint(0, 0.05), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        c.effects[0].curves.red = [CurvePoint(0, 0), CurvePoint(1, 0.9)]
        c.effects[0].hueCurves.hueVsSat = [CurvePoint(0, 0.5), CurvePoint(0.3, 0.8), CurvePoint(1, 0.5)]
        c.effects[0].wheels.shadows = WheelValue(hue: 10, amount: 0.2)
        c.effects[0].wheels.midtones = WheelValue(hue: 120, amount: 0.4)
        c.effects[0].wheels.highlights = WheelValue(hue: 240, amount: 0.6)
        c.effects[0].wheels.shadowsLuma = -10; c.effects[0].wheels.midtonesLuma = 5; c.effects[0].wheels.highlightsLuma = 8
        c.effects[0].wheels.saturation = 110
        c.effects[0].vignette.amount = -1.5; c.effects[0].vignette.midpoint = 40
        c.effects[0].vignette.roundness = 10; c.effects[0].vignette.feather = 70
        c.effects[0].setEnabled(.vignette, false)
        c.addEffect()
        c.effects[1].inputLUT = .file("/luts/second.cube"); c.effects[1].inputLUTIntensity = 35
        c.effects[1].basic.exposure = -0.5
        c.effects[1].setEnabled(.creative, false)
        return c
    }

    // MARK: Mapping

    @Test func everyFieldOfAColourEffectSurvivesTheEffectForm() {
        let g = Self.richGrade(media: UUID())
        for (i, e) in g.effects.enumerated() {
            let fx = ClipEffect.colorGrade(e)
            #expect(fx.kind == ClipEffect.colorKind)
            #expect(fx.colorEffect(atLocal: nil, id: i + 1) == e)
            #expect(fx.colorEffect(atLocal: Time(1, 1), id: i + 1) == e)
        }
    }

    @Test func theColourEffectIsInTheCatalogWithItsSectionToggles() throws {
        let spec = try #require(EffectCatalog.spec(for: ClipEffect.colorKind))
        #expect(EffectCatalog.all.contains { $0.kind == ClipEffect.colorKind })
        #expect(!EffectCatalog.isGeneratorOwned(ClipEffect.colorKind))
        let keys = spec.params.map(\.key)
        #expect(Set(keys).count == keys.count, "keys are unique")
        for k in [ClipEffect.colorBasicOnKey, ClipEffect.colorCreativeOnKey, ClipEffect.colorCurvesOnKey,
                  ClipEffect.colorWheelsOnKey, ClipEffect.colorVignetteOnKey] {
            #expect(EffectCatalog.param(ClipEffect.colorKind, k)?.kind == .checkbox)
        }
        #expect(EffectCatalog.param(ClipEffect.colorKind, ClipEffect.colorExposureKey)?.range == -5...5)
        // docs/VOCABULARY.md: the second section is "Creative" (display only; the keys keep their names).
        #expect(EffectCatalog.param(ClipEffect.colorKind, ClipEffect.colorCreativeOnKey)?.title == "Creative")
        #expect(ColorSectionKind.creative.title == "Creative")
        // A fresh instance is the neutral first effect.
        let fresh = try #require(ClipEffect.make(kind: ClipEffect.colorKind))
        #expect(fresh.colorEffect(atLocal: nil, id: 1) == ClipColor.defaultEffects[0])
    }

    // MARK: Clip.color as a view

    @Test func aClipWithoutAGradeHasNoColourEffect() {
        var c = Self.picture()
        #expect(c.color == .default)
        c.color = .default
        #expect(c.effects.isEmpty, "the neutral grade is not stored as an effect")
        c.color.source = .hlgBT2020
        #expect(c.effects.isEmpty && c.color.source == .hlgBT2020)
    }

    @Test func settingTheColourWritesColourEffects() {
        let media = UUID()
        var c = Self.picture(media: media)
        c.effects.append(ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!)
        let g = Self.richGrade(media: media)
        c.color = g
        #expect(c.color == g)
        #expect(c.effects.map(\.kind) == [ClipEffect.colorKind, ClipEffect.colorKind, ClipEffect.gaussianBlurKind],
                "color effects go in front of the other effects")
        // Removing the second effect through the view removes its ClipEffect, the first keeps its id.
        let first = c.effects[0].id
        var less = c.color
        less.removeEffect(2)
        c.color = less
        #expect(c.effects.filter { $0.kind == ClipEffect.colorKind }.map(\.id) == [first])
        // Adding one appends behind the existing color effect.
        var more = c.color
        more.addEffect()
        c.color = more
        #expect(c.effects.map(\.kind) == [ClipEffect.colorKind, ClipEffect.colorKind, ClipEffect.gaussianBlurKind])
        #expect(c.color.effects.count == 2 && c.color.effects[1].inputLUT == nil)
    }

    @Test func anEditAtAKeyedParameterSetsAKeyAndLeavesTheOthers() throws {
        var c = Self.picture()
        _ = c.addEffect(kind: ClipEffect.colorKind)
        let i = try #require(c.effects.firstIndex { $0.kind == ClipEffect.colorKind })
        var p = AnimatedProperty(0.0)
        p.track.insert(Keyframe(time: .zero, value: 0))
        p.track.insert(Keyframe(time: Time(2, 1), value: 2))
        c.effects[i].parameters[ClipEffect.colorExposureKey] = p
        #expect(c.color(atLocal: Time(1, 1)).effects[0].basic.exposure == 1)
        var g = c.color(atLocal: Time(1, 1))
        g.effects[0].basic.exposure = 1.5
        g.effects[0].basic.contrast = 30
        c.setColor(g, atLocal: Time(1, 1))
        let fx = c.effects[i]
        #expect(fx.parameters[ClipEffect.colorExposureKey]?.track.keys.map(\.time) == [.zero, Time(1, 1), Time(2, 1)])
        #expect(fx.parameters[ClipEffect.colorContrastKey]?.isAnimated == false)
        #expect(c.color(atLocal: Time(1, 1)).effects[0].basic.contrast == 30)
        #expect(c.color(atLocal: Time(2, 1)).effects[0].basic.exposure == 2)
        // The renderer sees the value at the frame.
        let t = Timeline(name: "S", format: SequenceFormat(width: 64, height: 36, frameDuration: Self.fd),
                         tracks: [Track(kind: .video, clips: [c])])
        #expect(t.videoLayers(at: Time(1, 1)).first?.color.effects[0].basic.exposure == 1.5)
        #expect(t.videoLayers(at: Time(1, 2)).first?.color.effects[0].basic.exposure == 0.75)
    }

    @Test func aSwitchedOffColourEffectRendersAsAbsent() throws {
        var c = Self.picture()
        c.color = Self.richGrade(media: c.media)
        let full = c.color
        c.effects[1].enabled = false
        var t = Timeline(name: "S", format: SequenceFormat(width: 64, height: 36, frameDuration: Self.fd),
                         tracks: [Track(kind: .video, clips: [c])])
        var shown = try #require(t.videoLayers(at: Time(1, 1)).first).color
        #expect(shown.effects == [full.effects[0]])
        // The first one off: a neutral conversion step stands in so the second keeps its display-referred role.
        c.effects[1].enabled = true
        c.effects[0].enabled = false
        try t.replaceClip(c)
        shown = try #require(t.videoLayers(at: Time(1, 1)).first).color
        #expect(shown.effects.count == 2)
        #expect(shown.effects[0] == ColorEffect(id: 1, inputLUT: full.effects[0].inputLUT), "neutral, same conversion")
        #expect(shown.effects[1] == full.effects[1])
        #expect(shown.source == full.source && shown.useEmbeddedLUT == full.useEmbeddedLUT)
        // The editing view still shows the switched-off effect.
        #expect(c.color.effects == full.effects)
    }

    // MARK: Migration (v26 -> v27)

    static func object(_ data: Data) throws -> ProjectFile.JSONObject {
        (try JSONSerialization.jsonObject(with: data) as? ProjectFile.JSONObject) ?? [:]
    }

    /// The first clip's JSON of the first track of the first timeline.
    static func firstClip(_ obj: ProjectFile.JSONObject) -> ProjectFile.JSONObject {
        let p = obj["project"] as? ProjectFile.JSONObject ?? [:]
        let tls = p["timelines"] as? [ProjectFile.JSONObject] ?? [[:]]
        let tracks = tls[0]["tracks"] as? [ProjectFile.JSONObject] ?? [[:]]
        let clips = tracks[0]["clips"] as? [ProjectFile.JSONObject] ?? [[:]]
        return clips[0]
    }

    /// A v26 project file whose clip stores the grade inside `color` (the old shape).
    static func v26File(grade: ClipColor, clip: Clip, extraEffects: [ClipEffect] = []) throws -> Data {
        var plain = clip
        plain.effects = extraEffects
        let tl = Timeline(name: "S", format: SequenceFormat(width: 64, height: 36, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [plain])])
        var obj = try object(ProjectFile.encode(Project(name: "P", timelines: [tl])))
        obj["formatVersion"] = 26
        var p = obj["project"] as? ProjectFile.JSONObject ?? [:]
        var tls = p["timelines"] as? [ProjectFile.JSONObject] ?? []
        var tracks = tls[0]["tracks"] as? [ProjectFile.JSONObject] ?? []
        var clips = tracks[0]["clips"] as? [ProjectFile.JSONObject] ?? []
        clips[0]["color"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grade))
        tracks[0]["clips"] = clips; tls[0]["tracks"] = tracks; p["timelines"] = tls; obj["project"] = p
        return try JSONSerialization.data(withJSONObject: obj)
    }

    @Test func currentVersionIs27() {
        #expect(ProjectFile.currentVersion >= 27)
        #expect(ProjectFile.realMigrations[26] != nil)
    }

    @Test func aV26GradeBecomesColourEffectsAndRendersTheSame() throws {
        let media = UUID()
        let grade = Self.richGrade(media: media)
        let blur = ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!
        let data = try Self.v26File(grade: grade, clip: Self.picture(media: media), extraEffects: [blur])
        // The old JSON really holds the grade in `color`.
        let oldColor = try JSONDecoder().decode(ClipColor.self, from: JSONEncoder().encode(grade))
        #expect(oldColor == grade)
        let p = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        let c = try #require(p.timelines.first?.tracks.first?.clips.first)
        #expect(c.effects.map(\.kind) == [ClipEffect.colorKind, ClipEffect.colorKind, ClipEffect.gaussianBlurKind])
        #expect(c.effects[2] == blur)
        #expect(c.color == grade)
        // LUT refs keep pointing where they did (the clip's own media, files).
        #expect(c.effects[0].colorData.inputLUT == .embedded(media))
        #expect(c.effects[0].colorData.look == .file("/luts/look.cube"))
        #expect(c.effects[1].colorData.inputLUT == .file("/luts/second.cube"))
        // What the renderer gets is exactly the old ClipColor, so the pipeline (and the pixels) are the same.
        let layer = try #require(p.timelines[0].videoLayers(at: Time(1, 1)).first)
        #expect(layer.color == grade)
    }

    @Test func aV26DefaultGradeAddsNoEffect() throws {
        var g = ClipColor.default
        g.source = .hlgBT2020
        let data = try Self.v26File(grade: g, clip: Self.picture())
        let project = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        let c = try #require(project.timelines[0].tracks[0].clips.first)
        #expect(c.effects.isEmpty)
        #expect(c.color == g)
    }

    @Test func theMigrationStepRewritesTheClipColour() throws {
        let data = try Self.v26File(grade: Self.richGrade(media: UUID()), clip: Self.picture())
        let step = try #require(ProjectFile.realMigrations[26])
        let clip = Self.firstClip(try step(Self.object(data)))
        let color = clip["color"] as? ProjectFile.JSONObject ?? [:]
        let hasEffects = color["effects"] != nil
        #expect(!hasEffects)
        let count = (clip["effects"] as? [Any])?.count ?? 0
        #expect(count == 2)
    }

    @Test func aV27ProjectRoundTrips() throws {
        var c = Self.picture()
        c.color = Self.richGrade(media: c.media)
        c.effects[0].parameters[ClipEffect.colorTemperatureKey]?.track.insert(Keyframe(time: Time(1, 1), value: 40))
        let tl = Timeline(name: "S", format: SequenceFormat(width: 64, height: 36, frameDuration: Self.fd),
                          tracks: [Track(kind: .video, clips: [c])])
        let p = Project(name: "P", timelines: [tl])
        let data = try ProjectFile.encode(p)
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0] == c)
        // The clip's `color` key holds only the footage interpretation.
        let color = Self.firstClip(try Self.object(data))["color"] as? ProjectFile.JSONObject ?? [:]
        #expect(Set(color.keys) == ["source", "useEmbeddedLUT"])
    }

    @Test func aNewerFileIsRefused() throws {
        let data = try ProjectFile.encode(Project(name: "P"))
        var obj = try Self.object(data)
        obj["formatVersion"] = ProjectFile.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: obj)
        #expect(throws: ProjectFileError.newerVersion(found: ProjectFile.currentVersion + 1, supported: ProjectFile.currentVersion)) {
            try ProjectFile.decode(newer, migrations: ProjectFile.migrations)
        }
    }

    // MARK: Copy, paste, presets, variants

    @Test func pasteAttributesCarriesTheGrade() throws {
        var src = Self.picture()
        src.color = Self.richGrade(media: src.media)
        var dst = Self.picture(media: src.media)   // same media: its embedded LUT exists there
        dst.color.effects[0].basic.exposure = 3
        let out = dst.pastingAttributes(from: src)
        #expect(out.color.effects == src.color.effects)
        #expect(out.effects.filter { $0.kind == ClipEffect.colorKind }.count == 2)
        // Pasting twice does not stack copies.
        #expect(out.pastingAttributes(from: src).effects.count == out.effects.count)
    }

    @Test func aPresetCarriesTheGrade() throws {
        var src = Self.picture()
        src.color = Self.richGrade(media: src.media)
        let preset = EffectPreset.capture(from: src)
        let back = try EffectPreset(payload: preset.payload(), version: EffectPreset.payloadVersion)
        #expect(back == preset)
        var dst = Self.picture(media: src.media)   // same media: its embedded LUT exists there
        dst.applyPreset(back)
        #expect(dst.color.effects == src.color.effects)
    }

    @Test func clipboardCopyCarriesTheGrade() throws {
        var c = Self.picture()
        c.color = Self.richGrade(media: c.media)
        let t = Timeline(name: "S", format: SequenceFormat(width: 64, height: 36, frameDuration: Self.fd),
                         tracks: [Track(kind: .video, clips: [c])])
        let cb = try #require(t.clipboard(copying: [c.id]))
        var other = Timeline(name: "T", format: t.format, tracks: [Track(kind: .video)])
        try other.paste(cb, at: Time(10, 1))
        let pasted = try #require(other.tracks[0].clips.first)
        #expect(pasted.color == c.color)
    }

    @Test func theGradeIsSharedByVariantsAndCanBeOverridden() throws {
        var c = Self.picture()
        c.color = Self.richGrade(media: c.media)
        var t = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Self.fd),
                         tracks: [Track(kind: .video, clips: [c])])
        let v = try t.addVariant(name: "9:16", width: 1080, height: 1920)
        #expect(t.videoLayers(at: Time(1, 1), variant: v).first?.color == c.color, "shared by default")
        let fx = c.effects[0].id
        try t.editOverride(clip: c.id, variant: v) { $0.effectParameters[fx] = [ClipEffect.colorExposureKey: AnimatedProperty(-2)] }
        #expect(t.videoLayers(at: Time(1, 1), variant: v).first?.color.effects[0].basic.exposure == -2)
        #expect(t.videoLayers(at: Time(1, 1)).first?.color.effects[0].basic.exposure == 1.25)
        // Removing the color effect drops its override.
        var n = try #require(t.find(c.id)?.clip)
        n.removeEffect(fx)
        #expect(n.variantOverrides[v]?.effectParameters[fx] == nil)
    }

    @Test func theEffectsPanelAddsALaterEffectWithoutInputLUT() throws {
        var c = Self.picture()
        _ = c.addEffect(kind: ClipEffect.colorKind)
        _ = c.addEffect(kind: ClipEffect.colorKind)
        #expect(c.color.effects.map(\.inputLUT) == [.automatic, nil])
    }

    // MARK: Review fixes (W5.2)

    /// A clip whose exposure and tint are keyed 0 -> 2 s.
    static func keyedClip() throws -> Clip {
        var c = picture()
        _ = c.addEffect(kind: ClipEffect.colorKind)
        let i = try #require(c.effects.firstIndex { $0.isColor })
        for (key, end) in [(ClipEffect.colorExposureKey, 2.0), (ClipEffect.colorTintKey, 20.0)] {
            var p = AnimatedProperty(0.0)
            p.track.insert(Keyframe(time: .zero, value: 0))
            p.track.insert(Keyframe(time: Time(2, 1), value: end))
            c.effects[i].parameters[key] = p
        }
        return c
    }

    /// Finding 2: the inspector holds values loaded at an earlier playhead. An edit of one slider must not write the
    /// other (stale) values as keys at the new time.
    @Test func anEditWritesOnlyTheEditedParameter() throws {
        var c = try Self.keyedClip()
        let base = c.color(atLocal: Time(1, 2))                  // loaded at 0.5 s: exposure 0.5, tint 5
        var edited = base
        edited.effects[0].basic.contrast = 20
        let ok1 = c.setColor(edited, editedFrom: base, atLocal: Time(3, 2))   // playhead moved on to 1.5 s
        #expect(ok1)
        let fx = try #require(c.effects.first { $0.isColor })
        #expect(fx.parameters[ClipEffect.colorExposureKey]?.track.keys.count == 2, "no stale key")
        #expect(fx.parameters[ClipEffect.colorTintKey]?.track.keys.count == 2, "no stale key")
        #expect(fx.parameters[ClipEffect.colorContrastKey]?.value == 20)
        // Editing a keyed value keys it at the given time only.
        var e2 = c.color(atLocal: Time(1, 1))
        let b2 = e2
        e2.effects[0].basic.exposure = 1.5
        let ok2 = c.setColor(e2, editedFrom: b2, atLocal: Time(1, 1))
        #expect(ok2)
        let fx2 = try #require(c.effects.first { $0.isColor })
        #expect(fx2.parameters[ClipEffect.colorExposureKey]?.track.keys.map(\.time) == [.zero, Time(1, 1), Time(2, 1)])
        #expect(fx2.parameters[ClipEffect.colorTintKey]?.track.keys.count == 2)
        // A changed LUT or curve only touches the grade data.
        var e3 = c.color(atLocal: Time(1, 1))
        let b3 = e3
        e3.effects[0].creative.look = .file("/l.cube")
        let ok3 = c.setColor(e3, editedFrom: b3, atLocal: Time(1, 1))
        #expect(ok3)
        #expect(c.color.effects[0].creative.look == .file("/l.cube"))
        #expect(c.effects.first { $0.isColor }?.parameters == fx2.parameters)
    }

    /// A clip without Color effects shows the neutral default as effect 1: an edit that adds effect 2 creates both.
    @Test func anEditOnAnUngradedClipCreatesEveryShownEffect() {
        var c = Self.picture()
        let base = c.color
        var edited = base
        edited.addEffect()
        edited.effects[1].wheels.saturation = 120
        let ok = c.setColor(edited, editedFrom: base, atLocal: .zero)
        #expect(ok)
        #expect(c.color.effects.count == 2 && c.color.effects[1].wheels.saturation == 120)
        #expect(c.color.effects[0] == ClipColor.defaultEffects[0])
        var neutral = Self.picture()
        let same = neutral.setColor(neutral.color, editedFrom: neutral.color, atLocal: .zero)
        #expect(same && neutral.effects.isEmpty)
    }

    /// Finding 7: an edit of a keyed value needs a time inside the clip; the last frame is the latest key time.
    @Test func editTimeStaysOnTheClipsFramesAndAKeyedEditOutsideIsRefused() throws {
        var c = try Self.keyedClip()                              // 0..4 s at 25 fps
        #expect(c.colorEditTime(atPlayhead: Time(4, 1), frameDuration: Self.fd) == nil)
        #expect(c.colorEditTime(atPlayhead: Time(-1, 1), frameDuration: Self.fd) == nil)
        #expect(c.colorEditTime(atPlayhead: Time(1, 1), frameDuration: Self.fd) == Time(1, 1))
        #expect(c.colorEditTime(atPlayhead: Time(4, 1) - Time(1, 100), frameDuration: Self.fd) == Time(4, 1) - Self.fd)
        let base = c.color(atLocal: Time(4, 1) - Self.fd)
        var keyed = base; keyed.effects[0].basic.exposure = 4
        let before = c
        let refused = c.setColor(keyed, editedFrom: base, atLocal: nil)
        #expect(!refused)
        #expect(c == before, "refused: nothing changes")
        var plain = base; plain.effects[0].basic.contrast = 10
        let ok = c.setColor(plain, editedFrom: base, atLocal: nil)
        #expect(ok, "an unkeyed value needs no time")
    }

    /// Finding 3: the renderer runs the color chain on media and stills only.
    @Test func colourIsRefusedOnNestedAndGeneratorClips() throws {
        var nested = Self.picture(); nested.sequence = UUID()
        var text = Self.picture(); text.generator = GeneratorRef.solid(rgb: [1, 2, 3])
        for var c in [nested, text] {
            #expect(!c.acceptsColor)
            let color = c.addEffect(kind: ClipEffect.colorKind)
            let blur = c.addEffect(kind: ClipEffect.gaussianBlurKind)
            #expect(color == nil && blur != nil)
            var src = Self.picture(); src.color = Self.richGrade(media: src.media)
            #expect(!c.pastingAttributes(from: src).effects.contains { $0.isColor })
        }
        #expect(Self.picture().acceptsColor)
    }

    /// Finding 4: color renders before every other effect, so the list keeps the Color effects first and in order.
    @Test func colourEffectsStayFirstInTheList() throws {
        var c = Self.picture()
        let blurID = c.addEffect(kind: ClipEffect.gaussianBlurKind)
        let aID = c.addEffect(kind: ClipEffect.colorKind)
        let bID = c.addEffect(kind: ClipEffect.colorKind)
        let blur = try #require(blurID), a = try #require(aID), b = try #require(bID)
        #expect(c.effects.map(\.id) == [a, b, blur], "added in front of the other effects")
        #expect(c.color.effects.map(\.inputLUT) == [.automatic, nil])
        let m1 = c.moveEffect(b, to: 0), m2 = c.moveEffect(a, to: 2), m3 = c.moveEffect(blur, to: 0)
        #expect(!m1, "a Color effect does not move (the first one is the conversion)")
        #expect(!m2)
        #expect(!m3, "nothing moves in front of the Color effects")
        #expect(c.effects.map(\.id) == [a, b, blur])
        let sharpenID = c.addEffect(kind: ClipEffect.sharpenKind)
        let sharpen = try #require(sharpenID)
        let m4 = c.moveEffect(sharpen, to: 0)
        #expect(m4)
        #expect(c.effects.map(\.id) == [a, b, sharpen, blur])
    }

    /// Finding 5: a switched-off first effect leaves the footage conversion exactly as it was.
    @Test func aSwitchedOffFirstEffectKeepsTheConversion() throws {
        for lut in [LUTRef?.none, .file("/c.cube"), .automatic] {
            var c = Self.picture()
            var g = ClipColor(source: .sLog3SGamut3Cine)
            g.effects[0].inputLUT = lut; g.effects[0].basic.exposure = 2
            c.color = g
            c.effects[0].enabled = false
            let shown = c.renderColor(atLocal: .zero)
            #expect(shown.effects.count == 1)
            #expect(shown.effects[0].inputLUT == lut, "\(String(describing: lut))")
            #expect(shown.effects[0].basic.isNeutral)
        }
        // Basic Correction off (= built-in conversion) stays off.
        var c = Self.picture()
        var g = ClipColor(source: .sLog3SGamut3Cine)
        g.effects[0].inputLUT = .file("/c.cube"); g.effects[0].setEnabled(.basicCorrection, false)
        c.color = g
        c.effects[0].enabled = false
        #expect(!c.renderColor(atLocal: .zero).effects[0].isEnabled(.basicCorrection))
    }

    /// Finding 6: Paste Color and Reset work on the effects themselves (keys and the effect switch included).
    @Test func replacingTheGradeCarriesKeysAndTheEffectSwitch() throws {
        var src = try Self.keyedClip()
        let i = try #require(src.effects.firstIndex { $0.isColor })
        src.effects[i].enabled = false
        src.footageColor = ClipFootageColor(source: .hlgBT2020, useEmbeddedLUT: false)
        var dst = Self.picture()
        _ = dst.addEffect(kind: ClipEffect.gaussianBlurKind)
        dst.footageColor = ClipFootageColor(source: .sLog3SGamut3Cine)
        dst.replaceColorGrade(with: src.colorGradeEffects)
        let fx = try #require(dst.effects.first)
        #expect(fx.isColor && !fx.enabled && fx.id != src.effects[i].id)
        #expect(fx.parameters[ClipEffect.colorExposureKey]?.track.keys.count == 2)
        #expect(dst.effects.count == 2)
        #expect(dst.footageColor.source == .sLog3SGamut3Cine, "the target keeps its interpretation")
        dst.replaceColorGrade(with: [])
        #expect(!dst.effects.contains { $0.isColor })
    }
}

/// Re-review: a LUT embedded in another clip's media does not travel; paste paths keep color first and color-capable.
@Suite struct ColorPasteLUTTests {
    /// Two Color effects whose LUT refs point into `media`'s embedded LUT, plus a file look on the second.
    static func embeddedGrade(media m: UUID) -> [ClipEffect] {
        var src = ColorGradeEffectTests.picture(media: m)
        var g = ClipColor.default
        g.effects[0].inputLUT = .embedded(m); g.effects[0].creative.look = .embedded(m)
        g.addEffect(); g.effects[1].inputLUT = .embedded(m); g.effects[1].creative.look = .file("/a.cube")
        src.color = g
        return src.colorGradeEffects
    }

    @Test func replacingTheGradeDropsTheOtherMediasEmbeddedLUT() {
        let m = UUID()
        var dst = ColorGradeEffectTests.picture()
        dst.replaceColorGrade(with: Self.embeddedGrade(media: m))
        let fx = dst.colorGradeEffects
        #expect(fx.count == 2)
        #expect(fx[0].grade?.inputLUT == .automatic && fx[0].grade?.look == nil)
        #expect(fx[1].grade?.inputLUT == nil && fx[1].grade?.look == .file("/a.cube"), "file LUTs travel")
        // The clip's own media keeps its embedded LUT.
        var same = ColorGradeEffectTests.picture(media: m)
        same.replaceColorGrade(with: Self.embeddedGrade(media: m))
        #expect(same.colorGradeEffects[0].grade?.inputLUT == .embedded(m))
    }

    @Test func pasteAttributesDropsTheOtherMediasEmbeddedLUT() {
        let m = UUID()
        var src = ColorGradeEffectTests.picture(media: m)
        src.effects = Self.embeddedGrade(media: m)
        let r = ColorGradeEffectTests.picture().pastingAttributes(from: src)
        #expect(r.colorGradeEffects.first?.grade?.inputLUT == .automatic)
    }

    @Test func presetsDropEmbeddedLUTs() {
        let preset = EffectPreset(referenceDuration: Time(4, 1), effects: Self.embeddedGrade(media: UUID()))
        var dst = ColorGradeEffectTests.picture()
        dst.applyPreset(preset)
        let fx = dst.colorGradeEffects
        #expect(fx.count == 2 && fx[0].grade?.inputLUT == .automatic && fx[0].grade?.look == nil)
        #expect(fx[1].grade?.inputLUT == nil)
        // Behind an existing color effect the first preset effect is not the primary: no conversion.
        var graded = ColorGradeEffectTests.picture()
        _ = graded.addEffect(kind: ClipEffect.colorKind)
        graded.applyPreset(preset)
        #expect(graded.colorGradeEffects.count == 3 && graded.colorGradeEffects[1].grade?.inputLUT == nil)
    }

    @Test func aPastedColourEffectGoesBehindTheColourBlockAndOnlyOnColourClips() throws {
        let m = UUID()
        let e = try #require(Self.embeddedGrade(media: m).first)
        var dst = ColorGradeEffectTests.picture()
        _ = dst.addEffect(kind: ClipEffect.gaussianBlurKind)
        let ok1 = dst.insertPastedEffect(e)
        #expect(ok1)
        #expect(dst.effects.count == 2 && dst.effects[0].isColor && dst.effects[0].id != e.id)
        #expect(dst.effects[0].grade?.inputLUT == .automatic, "another media's embedded LUT is dropped")
        let ok2 = dst.insertPastedEffect(e)
        #expect(ok2)
        #expect(dst.effects.map(\.isColor) == [true, true, false])
        #expect(dst.effects[1].grade?.inputLUT == nil, "only the first color effect converts")
        var nested = ColorGradeEffectTests.picture(); nested.sequence = UUID()
        var text = ColorGradeEffectTests.picture(); text.generator = GeneratorRef.solid(rgb: [1, 2, 3])
        let r1 = nested.insertPastedEffect(e), r2 = text.insertPastedEffect(e)
        #expect(!r1 && !r2)
        #expect(nested.effects.isEmpty && text.effects.isEmpty)
        // Other effects are appended as before.
        let blur = try #require(dst.effects.last)
        let r3 = text.insertPastedEffect(blur)
        #expect(r3 && text.effects.count == 1 && text.effects[0].id != blur.id)
    }
}
