import Foundation
import Testing
@testable import SQCore

/// W5.1: editing in a variant, the materialised variant view (no per-frame resolution), nesting / paste / effect removal
/// / Duplicate as Format keep overrides consistent, the active variant is stored in the project.
@Suite struct FormatVariantsW5Tests {
    typealias F = FormatVariantsTests

    // MARK: Edits made while a variant is shown

    @Test func motionEditInAVariantWritesTheOverrideNotTheBase() throws {
        let c = F.picture(pos: Vec2(100, 50))
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        var shown = t.resolvedClip(t.find(c.id)!.clip, variant: v)
        shown.animation.position.value = Vec2(7, 8)
        try t.applyDisplayedEdit(shown, variant: v, conformsPicture: true)
        let after = try #require(t.find(c.id)?.clip)
        #expect(after.animation.position.value == Vec2(100, 50))
        #expect(after.variantOverrides[v]?.position?.value == Vec2(7, 8))
        #expect(after.variantOverrides[v]?.scale == nil)          // only what changed is detached
        #expect(t.resolvedClip(after, variant: v).animation.position.value == Vec2(7, 8))
    }

    @Test func tiltEditInAVariantWritesTheOverrideNotTheBase() throws {
        var c = F.picture()
        c.animation.tiltX.value = 10
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        var shown = t.resolvedClip(t.find(c.id)!.clip, variant: v)
        #expect(shown.animation.tiltX.value == 10)                // inherited until overridden
        shown.animation.tiltY.value = 30
        try t.applyDisplayedEdit(shown, variant: v, conformsPicture: true)
        let after = try #require(t.find(c.id)?.clip)
        #expect(after.animation.tiltY.value == 0 && after.animation.tiltX.value == 10)
        #expect(after.variantOverrides[v]?.tiltY?.value == 30)
        #expect(after.variantOverrides[v]?.tiltX == nil)          // only what changed is detached
        #expect(try #require(t.videoLayers(at: .zero, variant: v).first).transform.tiltY == 30)
        #expect(try #require(t.videoLayers(at: .zero).first).transform.tiltY == 0)
    }

    @Test func tiltDetachAndResetFollowTheProperty() throws {
        var c = F.picture()
        c.animation.tiltX.value = 12
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        try t.detach([.tilt], clip: c.id, variant: v)
        #expect(t.override(of: c.id, in: v)?.has(.tilt) == true)
        #expect(t.override(of: c.id, in: v)?.tiltX?.value == 12)
        try t.resetOverride(.tilt, clip: c.id, variant: v)
        #expect(t.override(of: c.id, in: v) == nil)
    }

    @Test func tiltOverrideRoundTripsAndGatesV84() throws {
        let c = F.picture()
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        let plain = try JSONSerialization.jsonObject(with: try ProjectFile.encode(Project(name: "P", timelines: [t]))) as! [String: Any]
        #expect((plain["formatVersion"] as? Int ?? 99) < 84)      // an old project is not bumped
        try t.editOverride(clip: c.id, variant: v) { $0.tiltX = AnimatedProperty(25.0) }
        let project = Project(name: "P", timelines: [t])
        let data = try ProjectFile.encode(project)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["formatVersion"] as? Int == 84)
        for m in [nil, ProjectFile.migrations] {
            let back = try ProjectFile.decode(data, migrations: m)
            #expect(back.timelines[0].override(of: c.id, in: v)?.tiltX?.value == 25)
        }
    }

    @Test func sharedPropertiesEditedInAVariantGoToTheBase() throws {
        let c = F.picture()
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        var shown = t.resolvedClip(t.find(c.id)!.clip, variant: v)
        shown.animation.opacity.value = 0.25
        try t.applyDisplayedEdit(shown, variant: v, conformsPicture: true)
        let after = try #require(t.find(c.id)?.clip)
        #expect(after.animation.opacity.value == 0.25)
        #expect(after.animation.scale.value == Vec2(1, 1))         // the auto-conformed scale is not written back
        #expect(after.variantOverrides.isEmpty)
    }

    @Test func overriddenEffectParameterStaysPerVariantOthersAreShared() throws {
        var c = F.picture()
        let crop = ClipEffect(kind: ClipEffect.cropKind, parameters: [ClipEffect.cropLeftKey: AnimatedProperty(10),
                                                                     ClipEffect.cropRightKey: AnimatedProperty(5)])
        c.effects = [crop]
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.effectParameters[crop.id] = [ClipEffect.cropLeftKey: AnimatedProperty(30)] }
        var shown = t.resolvedClip(t.find(c.id)!.clip, variant: v)
        shown.effects[0].parameters[ClipEffect.cropLeftKey] = AnimatedProperty(40)
        shown.effects[0].parameters[ClipEffect.cropRightKey] = AnimatedProperty(6)
        try t.applyDisplayedEdit(shown, variant: v, conformsPicture: true)
        let after = try #require(t.find(c.id)?.clip)
        #expect(after.effects[0].parameters[ClipEffect.cropLeftKey]?.value == 10)
        #expect(after.effects[0].parameters[ClipEffect.cropRightKey]?.value == 6)
        #expect(after.variantOverrides[v]?.effectParameters[crop.id]?[ClipEffect.cropLeftKey]?.value == 40)
    }

    @Test func removingAnEffectInAVariantDropsItsOverrides() throws {
        var c = F.picture()
        let crop = ClipEffect(kind: ClipEffect.cropKind, parameters: [ClipEffect.cropLeftKey: AnimatedProperty(10)])
        c.effects = [crop]
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) {
            $0.effectParameters[crop.id] = [ClipEffect.cropLeftKey: AnimatedProperty(30)]
            $0.rotation = AnimatedProperty(5)
        }
        var shown = t.resolvedClip(t.find(c.id)!.clip, variant: v)
        shown.removeEffect(crop.id)
        try t.applyDisplayedEdit(shown, variant: v, conformsPicture: true)
        let after = try #require(t.find(c.id)?.clip)
        #expect(after.effects.isEmpty)
        #expect(after.variantOverrides[v]?.effectParameters.isEmpty == true)
        #expect(after.variantOverrides[v]?.rotation?.value == 5)
    }

    @Test func displayedEditWithoutVariantReplacesTheClip() throws {
        let c = F.picture()
        var t = F.timeline([c])
        _ = try F.vertical(&t)
        var n = c
        n.animation.position.value = Vec2(1, 1)
        try t.applyDisplayedEdit(n, variant: nil, conformsPicture: true)
        #expect(t.find(c.id)?.clip.animation.position.value == Vec2(1, 1))
        #expect(t.find(c.id)?.clip.variantOverrides.isEmpty == true)
    }

    // MARK: Effect removal and paste prune

    @Test func clipRemoveEffectDropsThatEffectsOverridesInEveryVariant() throws {
        var c = F.picture()
        let crop = ClipEffect(kind: ClipEffect.cropKind, parameters: [ClipEffect.cropLeftKey: AnimatedProperty(10)])
        c.effects = [crop]
        let v = UUID()
        c.variantOverrides[v] = VariantOverride(effectParameters: [crop.id: [ClipEffect.cropLeftKey: AnimatedProperty(3)]])
        let removed = c.removeEffect(crop.id)
        #expect(removed)
        #expect(c.variantOverrides.isEmpty)
    }

    @Test func pasteIntoAnotherSequenceDropsOverridesForVariantsItDoesNotHave() throws {
        let c = F.picture()
        var src = F.timeline([c])
        let v = try F.vertical(&src)
        try src.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(1, 2)) }
        let cb = try #require(src.clipboard(copying: [c.id]))
        var dst = F.timeline([])
        let ids = try dst.paste(cb, at: Time(10, 1))
        #expect(dst.find(ids[0])?.clip.variantOverrides.isEmpty == true)
        // Same sequence: the overrides come along.
        let again = try src.paste(cb, at: Time(10, 1))
        #expect(src.find(again[0])?.clip.variantOverrides[v]?.position?.value == Vec2(1, 2))
    }

    // MARK: Nesting

    @Test func nestKeepsOverridesAndTheVariantPicture() throws {
        let c = F.picture(pos: Vec2(100, 50))
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(-200, 300)) }
        var p = Project(name: "p", timelines: [t])
        let before = p.timeline(t.id)!.videoLayers(at: Time(1, 1), variant: v)
        let seq = try p.nest(clips: [c.id], in: t.id)
        let inner = try #require(p.timeline(seq))
        #expect(inner.variants.map(\.id) == [v])
        #expect(inner.find(c.id)?.clip.variantOverrides[v]?.position?.value == Vec2(-200, 300))
        let pruned = p.pruneVariantOverrides()
        #expect(!pruned)                                          // nothing left dangling
        let after = p.timeline(t.id)!.videoLayers(at: Time(1, 1), sequences: { p.timeline($0) }, variant: v)
        let l = try #require(after.first)
        // Inner sequence rendered in its 9:16 variant, the nested clip not conformed a second time.
        #expect(l.groups.first?.format.width == 1080 && l.groups.first?.format.height == 1920)
        #expect(l.groups.first?.transform.scale == Vec2(1, 1))
        #expect(l.transform == before.first?.transform)
    }

    static func nested(_ inner: Timeline) -> Clip {
        Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero,
             sequence: inner.id)
    }

    /// The display / edit path matches render: a nested clip whose inner sequence has the same variant is not conformed.
    @Test func nestedClipIsDisplayedAndEditedUnconformedWhenItsSequenceHasTheVariant() throws {
        var inner = F.timeline([F.picture()])
        let v = try F.vertical(&inner)
        let n = Self.nested(inner)
        let plain = F.picture()
        var t = Timeline(name: "S", format: F.base, tracks: [Track(kind: .video, clips: [n]), Track(kind: .video, clips: [plain])])
        t.variants = inner.variants                                    // same id
        let p0 = Project(name: "p", timelines: [t, inner])
        #expect(!p0.conformsPicture(of: n, in: v))
        #expect(p0.conformsPicture(of: plain, in: v))
        let shown = p0.displayedClip(n, in: t, variant: v)
        #expect(shown.animation.scale.value == Vec2(1, 1))
        #expect(p0.displayedClip(plain, in: t, variant: v).animation.scale.value != Vec2(1, 1))
        let size = try #require(p0.pictureSize(of: n, variant: v))
        #expect(size.width == 1080 && size.height == 1920)
        #expect(p0.pictureSize(of: n, variant: nil)?.width == 1920)

        var edited = shown
        edited.animation.rotation.value = 10
        var t2 = t
        try t2.applyDisplayedEdit(edited, variant: v, conformsPicture: p0.conformsPicture(of: n, in: v))
        let o = try #require(t2.override(of: n.id, in: v))
        #expect(o.rotation?.value == 10)
        #expect(o.scale == nil && o.position == nil)                    // nothing conformed written into the override
        let p = Project(name: "p", timelines: [t2, inner])
        let view = try #require(p.variantView(of: t.id, variant: v))
        #expect(view.timeline.find(n.id)?.clip.animation.scale.value == Vec2(1, 1))
        #expect(p.displayedClip(t2.find(n.id)!.clip, in: t2, variant: v).animation == view.timeline.find(n.id)?.clip.animation)
    }

    /// A sequence reachable two ways (directly and through a chain) is materialised once, never conformed twice.
    @Test func variantViewDoesNotConformASequenceReachedTwoWays() throws {
        var x = F.timeline([F.picture()])
        let v = try F.vertical(&x)
        var z = F.timeline([Self.nested(x)]); z.variants = x.variants
        var y = F.timeline([Self.nested(z)]); y.variants = x.variants
        var t = Timeline(name: "T", format: F.base, tracks: [Track(kind: .video, clips: [Self.nested(x)]),
                                                             Track(kind: .video, clips: [Self.nested(y)])])
        t.variants = x.variants
        let p = Project(name: "p", timelines: [t, x, y, z])
        let view = try #require(p.variantView(of: t.id, variant: v))
        #expect(view.sequences[z.id]?.tracks[0].clips.first?.animation.scale.value == Vec2(1, 1))
        #expect(view.sequences[y.id]?.tracks[0].clips.first?.animation.scale.value == Vec2(1, 1))
        #expect(view.timeline.tracks[0].clips.first?.animation.scale.value == Vec2(1, 1))
    }

    // MARK: Materialised variant view

    @Test func variantViewMatchesPerFrameResolution() throws {
        var a = F.picture(.zero, Time(2, 1), pos: Vec2(30, 40))
        a.animation.position.track.insert(Keyframe(time: .zero, value: Vec2(0, 0)))
        a.animation.position.track.insert(Keyframe(time: Time(1, 1), value: Vec2(200, 0)))
        let b = F.text()
        var t = Timeline(name: "S", format: F.base, tracks: [Track(kind: .video, clips: [a]), Track(kind: .video, clips: [b])])
        let v = try F.vertical(&t)
        try t.editOverride(clip: b.id, variant: v) { $0.scale = AnimatedProperty(Vec2(2, 2)) }
        let p = Project(name: "p", timelines: [t])
        let view = try #require(p.variantView(of: t.id, variant: v))
        #expect(view.timeline.format == t.format(for: v))
        #expect(view.timeline.variants.isEmpty)
        for f in 0..<60 {
            let at = Time(Int64(f), 30)
            #expect(view.timeline.videoLayers(at: at, sequences: { view.sequences[$0] })
                    == t.videoLayers(at: at, sequences: { p.timeline($0) }, variant: v))
        }
        // No variant: the timeline as it is.
        #expect(p.variantView(of: t.id, variant: nil)?.timeline == t)
    }

    @Test func variantViewMaterialisesNestedSequencesThatShareTheVariant() throws {
        let c = F.picture(pos: Vec2(100, 50))
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(-200, 300)) }
        var p = Project(name: "p", timelines: [t])
        let seq = try p.nest(clips: [c.id], in: t.id)
        let view = try #require(p.variantView(of: t.id, variant: v))
        #expect(view.sequences[seq]?.format.width == 1080)
        for f in [0, 15, 45] {
            let at = Time(Int64(f), 30)
            #expect(view.timeline.videoLayers(at: at, sequences: { view.sequences[$0] })
                    == p.timeline(t.id)!.videoLayers(at: at, sequences: { p.timeline($0) }, variant: v))
        }
    }

    /// Measurement for the per-frame cost W4 left open: playback and export evaluate the materialised view, so no clip is
    /// resolved per frame. Prints both timings; the view must not be slower.
    @Test func variantViewAvoidsPerFrameResolution() throws {
        var clips: [Clip] = []
        for i in 0..<40 {
            var c = F.picture(Time(Int64(i), 10), Time(4, 1), pos: Vec2(Double(i), 0))
            for k in 0..<20 { c.animation.position.track.insert(Keyframe(time: Time(Int64(k), 10), value: Vec2(Double(k), 1))) }
            clips.append(c)
        }
        var t = Timeline(name: "S", format: F.base, tracks: (0..<4).map { i in
            Track(kind: .video, clips: clips.enumerated().filter { $0.offset % 4 == i }.map(\.element).enumerated().map { j, c in
                var n = c; n.start = Time(Int64(j) * 4, 1); return n
            })
        })
        let v = try F.vertical(&t)
        let p = Project(name: "p", timelines: [t])
        let view = try #require(p.variantView(of: t.id, variant: v))
        let frames = (0..<600).map { Time(Int64($0), 30) }
        let clock = ContinuousClock()
        var sink = 0
        // Best of 9, alternating, so a busy parallel test run does not decide the comparison.
        var perFrame = Duration.seconds(1000), materialised = Duration.seconds(1000)
        for _ in 0..<9 {
            perFrame = min(perFrame, clock.measure { for at in frames { sink += t.videoLayers(at: at, variant: v).count } })
            materialised = min(materialised, clock.measure { for at in frames { sink += view.timeline.videoLayers(at: at).count } })
        }
        print("variant evaluation, 600 frames: per-frame resolve \(perFrame), materialised \(materialised)")
        #expect(sink > 0)
        #expect(materialised < perFrame * 2)
    }

    // MARK: Duplicate as Format, Change Format

    @Test func duplicateAsFormatGivesVariantsFreshIDsAndKeepsOverrides() throws {
        let c = F.picture()
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(5, 6)) }
        var p = Project(name: "p", timelines: [t])
        let copyID = try p.duplicateSequence(t.id, as: SequenceFormat(width: 1080, height: 1080, frameDuration: F.fd), mode: .fill)
        let copy = try #require(p.timeline(copyID))
        #expect(copy.variants.count == 1)
        let nv = try #require(copy.variants.first?.id)
        #expect(nv != v)
        #expect(copy.variants.first?.name == "9:16")
        let clip = try #require(copy.tracks.flatMap(\.clips).first)
        #expect(clip.variantOverrides.keys.map { $0 } == [nv])
        #expect(clip.variantOverrides[nv]?.position?.value == Vec2(5, 6))
    }

    /// Variants a nested clip's inner sequence shares keep their id in the copy, so nested clips still render in the
    /// inner variant; the others get fresh ids.
    @Test func duplicateAsFormatKeepsVariantIDsSharedWithNestedSequences() throws {
        var inner = F.timeline([F.picture()])
        let v = try F.vertical(&inner)
        var t = F.timeline([Self.nested(inner)])
        t.variants = inner.variants
        let square = try t.addVariant(name: "1:1", width: 1080, height: 1080)
        var p = Project(name: "p", timelines: [t, inner])
        let copyID = try p.duplicateSequence(t.id, as: F.base, mode: .fill)
        let copy = try #require(p.timeline(copyID))
        #expect(copy.variants.count == 2)
        #expect(copy.variant(v) != nil)
        #expect(copy.variant(square) == nil)
        let view = try #require(p.variantView(of: copyID, variant: v))
        #expect(view.timeline.tracks[0].clips.first?.animation.scale.value == Vec2(1, 1))
        #expect(view.sequences[inner.id]?.format.width == 1080)
    }

    @Test func duplicateAsFormatKeepsTrackAudioRoles() throws {
        var a = Track(kind: .audio)
        a.audioRole = .music
        let t = Timeline(name: "S", format: F.base, tracks: [Track(kind: .video), a])
        var p = Project(name: "p", timelines: [t])
        let copyID = try p.duplicateSequence(t.id, as: SequenceFormat(width: 1080, height: 1920, frameDuration: F.fd), mode: .fill)
        #expect(p.timeline(copyID)?.tracks.last?.audioRole == .music)
        #expect(p.timeline(copyID)?.tracks.last?.id != a.id)
    }

    @Test func changeFormatKeepsVariantsAndOverrides() throws {
        let c = F.picture()
        var t = F.timeline([c])
        let v = try F.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(5, 6)) }
        var p = Project(name: "p", timelines: [t])
        try p.changeFormat(of: t.id, to: SequenceFormat(width: 3840, height: 2160, frameDuration: F.fd), mode: .fill)
        let after = try #require(p.timeline(t.id))
        #expect(after.variants.map(\.id) == [v])
        #expect(after.find(c.id)?.clip.variantOverrides[v]?.position?.value == Vec2(5, 6))
        // The automatic part follows the new base (scale 2 in 4K, fill factor 1920/2160): the 9:16 picture is unchanged.
        let scale = after.resolvedClip(after.find(c.id)!.clip, variant: v).animation.scale.value.x
        #expect(abs(scale - 1920.0 / 1080.0) < 1e-9)
    }

    // MARK: Active variant in the project file

    @Test func activeVariantsRoundTripThroughTheProjectFile() throws {
        var t = F.timeline([])
        let v = try F.vertical(&t)
        var p = Project(name: "p", timelines: [t])
        p.activeVariants = [t.id: v]
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.activeVariants == [t.id: v])
    }

    @Test func activeVariantsAreDroppedForUnknownSequencesOrVariants() throws {
        var t = F.timeline([])
        let v = try F.vertical(&t)
        var p = Project(name: "p", timelines: [t])
        p.activeVariants = [t.id: UUID(), UUID(): v]
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back.activeVariants.isEmpty)
        p.activeVariants = [t.id: v]
        #expect(p.activeVariant(of: t.id) == v)
        p.timelines[0].variants = []
        #expect(p.activeVariant(of: t.id) == nil)
    }

    @Test func projectWithoutActiveVariantsDecodes() throws {
        let p = Project(name: "p", timelines: [F.timeline([])])
        let data = try ProjectFile.encode(p)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("activeVariants"))
        #expect(try ProjectFile.decode(data, migrations: ProjectFile.migrations).activeVariants.isEmpty)
    }
}
