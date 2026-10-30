import Foundation
import Testing
@testable import SQCore

/// W4.1: one shared edit, several frame sizes. Overrides are sparse and per clip per variant; anything not overridden
/// is the base value conformed automatically (design note (a) in docs/ROADMAP.md).
@Suite struct FormatVariantsTests {
    static let fd = Time(1, 30)
    static let base = SequenceFormat(width: 1920, height: 1080, frameDuration: fd)

    static func picture(_ start: Time = .zero, _ len: Time = Time(4, 1), pos: Vec2 = Vec2(100, 50),
                        scale: Vec2 = Vec2(1, 1)) -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)),
                     start: start, mediaDuration: Time(10, 1))
        c.source = TimeRange(start: .zero, duration: len)
        c.animation.position.value = pos
        c.animation.scale.value = scale
        return c
    }

    static func text(pos: Vec2 = Vec2(0, 400)) -> Clip {
        let id = UUID()
        var c = Clip(id: id, name: "t", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                     start: .zero, generator: GeneratorRef(kind: GeneratorRef.text, payload: Data([1, 2, 3])))
        c.animation.position.value = pos
        return c
    }

    static func timeline(_ clips: [Clip]) -> Timeline {
        Timeline(name: "S", format: base, tracks: [Track(kind: .video, clips: clips), Track(kind: .audio)])
    }

    static func vertical(_ t: inout Timeline, conform: ConformMode = .fill) throws -> FormatVariant.ID {
        try t.addVariant(name: "9:16", width: 1080, height: 1920, conform: conform)
    }

    // MARK: Variants on the timeline

    @Test func addVariantStoresSizeAndKeepsTheBaseFormat() throws {
        var t = Self.timeline([Self.picture()])
        let v = try Self.vertical(&t)
        #expect(t.variants.count == 1)
        #expect(t.variant(v)?.name == "9:16")
        #expect(t.format == Self.base)
        let f = t.format(for: v)
        #expect(f.width == 1080 && f.height == 1920)
        #expect(f.frameDuration == Self.fd && f.audioSampleRate == Self.base.audioSampleRate)
        #expect(t.format(for: nil) == Self.base)
        #expect(t.format(for: UUID()) == Self.base)
    }

    @Test func addVariantRefusesAnInvalidSize() {
        var t = Self.timeline([])
        #expect(throws: EditError.invalidFormat) { try t.addVariant(name: "x", width: 0, height: 100) }
        #expect(throws: EditError.invalidFormat) { try t.addVariant(name: "x", width: 100, height: -1) }
        #expect(t.variants.isEmpty)
    }

    @Test func renameResizeAndConformModeOfAVariant() throws {
        var t = Self.timeline([])
        let v = try Self.vertical(&t)
        try t.renameVariant(v, to: "Reels")
        try t.setVariantSize(v, width: 1080, height: 1350)
        try t.setVariantConform(v, .fit)
        #expect(t.variant(v) == FormatVariant(id: v, name: "Reels", width: 1080, height: 1350, conform: .fit))
        #expect(throws: EditError.invalidFormat) { try t.setVariantSize(v, width: 0, height: 10) }
        #expect(throws: VariantError.variantNotFound) { try t.renameVariant(UUID(), to: "x") }
    }

    @Test func removeVariantDropsItsOverridesFromEveryClip() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        let w = try t.addVariant(name: "1:1", width: 1080, height: 1080)
        try t.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(1, 2)) }
        try t.editOverride(clip: c.id, variant: w) { $0.position = AnimatedProperty(Vec2(3, 4)) }
        try t.removeVariant(v)
        #expect(t.variants.map(\.id) == [w])
        let after = try #require(t.find(c.id)?.clip)
        #expect(after.variantOverrides.keys.sorted { $0.uuidString < $1.uuidString } == [w])
        #expect(throws: VariantError.variantNotFound) { try t.removeVariant(v) }
    }

    // MARK: Sparse storage

    @Test func aClipWithoutOverridesStoresNothing() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        _ = try Self.vertical(&t)
        let data = try JSONEncoder().encode(t.find(c.id)!.clip)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("variantOverrides"))
    }

    @Test func emptyingAnOverrideRemovesIt() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.scale = AnimatedProperty(Vec2(2, 2)) }
        #expect(t.override(of: c.id, in: v)?.scale != nil)
        try t.editOverride(clip: c.id, variant: v) { $0.scale = nil }
        #expect(t.override(of: c.id, in: v) == nil)
        #expect(t.find(c.id)!.clip.variantOverrides.isEmpty)
        let text = String(decoding: try JSONEncoder().encode(t.find(c.id)!.clip), as: UTF8.self)
        #expect(!text.contains("variantOverrides"))
    }

    @Test func settingAnEmptyOverrideIsTheSameAsNone() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.setOverride(VariantOverride(), clip: c.id, variant: v)
        #expect(t.find(c.id)!.clip.variantOverrides.isEmpty)
        #expect(VariantOverride().isEmpty)
    }

    @Test func overrideOnAnUnknownClipOrVariantThrows() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        #expect(throws: EditError.clipNotFound) { try t.editOverride(clip: UUID(), variant: v) { o in o.rotation = AnimatedProperty(5) } }
        #expect(throws: VariantError.variantNotFound) { try t.editOverride(clip: c.id, variant: UUID()) { o in o.rotation = AnimatedProperty(5) } }
    }

    @Test func overridesAreStoredOnlyForTheVariantThatWasEdited() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        let w = try t.addVariant(name: "1:1", width: 1080, height: 1080)
        try t.editOverride(clip: c.id, variant: v) { $0.rotation = AnimatedProperty(10) }
        #expect(t.override(of: c.id, in: v)?.rotation?.value == 10)
        #expect(t.override(of: c.id, in: w) == nil)
        #expect(t.find(c.id)!.clip.animation.rotation.value == 0)
    }

    // MARK: Override resolution

    @Test func baseEvaluationIgnoresVariants() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(-300, 0)) }
        let layers = t.videoLayers(at: Time(1, 1))
        #expect(layers.count == 1)
        #expect(layers[0].transform.position == Vec2(100, 50))
        #expect(t.videoLayers(at: Time(1, 1), variant: nil) == layers)
    }

    @Test func missingOverrideIsTheAutomaticConformOfTheBase() throws {
        // 1920x1080 -> 1080x1920 fill: factor max(1080/1920, 1920/1080) = 1920/1080.
        let c = Self.picture(pos: Vec2(90, 54), scale: Vec2(1, 1))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t, conform: .fill)
        let k = 1920.0 / 1080.0
        let tr = try #require(t.videoLayers(at: Time(1, 1), variant: v).first).transform
        #expect(abs(tr.position.x - 90 * k) < 1e-9 && abs(tr.position.y - 54 * k) < 1e-9)
        #expect(abs(tr.scale.x - k) < 1e-9 && abs(tr.scale.y - k) < 1e-9)
        #expect(tr.rotation == 0 && tr.opacity == 1)
    }

    @Test func fitConformUsesTheSmallerFactor() throws {
        let c = Self.picture(pos: Vec2(0, 0), scale: Vec2(2, 2))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t, conform: .fit)
        let tr = try #require(t.videoLayers(at: .zero, variant: v).first).transform
        let k = 1080.0 / 1920.0
        #expect(abs(tr.scale.x - 2 * k) < 1e-9)
    }

    @Test func perClipConformModeWinsOverTheVariants() throws {
        let c = Self.picture(pos: .zero, scale: Vec2(1, 1))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t, conform: .fill)
        try t.editOverride(clip: c.id, variant: v) { $0.conform = .fit }
        let tr = try #require(t.videoLayers(at: .zero, variant: v).first).transform
        #expect(abs(tr.scale.x - 1080.0 / 1920.0) < 1e-9)
    }

    @Test func overriddenPropertyIsUsedAsIsAndTheOthersStayAutomatic() throws {
        let c = Self.picture(pos: Vec2(90, 54), scale: Vec2(1, 1))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(-200, 10)) }
        let tr = try #require(t.videoLayers(at: Time(1, 1), variant: v).first).transform
        #expect(tr.position == Vec2(-200, 10))                    // not conformed again
        #expect(abs(tr.scale.x - 1920.0 / 1080.0) < 1e-9)         // still automatic
    }

    @Test func rotationAndAnchorOverrides() throws {
        var c = Self.picture()
        c.animation.rotation.value = 5
        c.animation.anchor.value = Vec2(1, 1)
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        #expect(try #require(t.videoLayers(at: .zero, variant: v).first).transform.rotation == 5)
        try t.editOverride(clip: c.id, variant: v) {
            $0.rotation = AnimatedProperty(-90)
            $0.anchor = AnimatedProperty(Vec2(7, 8))
        }
        let tr = try #require(t.videoLayers(at: .zero, variant: v).first).transform
        #expect(tr.rotation == -90 && tr.anchor == Vec2(7, 8))
    }

    @Test func keyframedOverrideIsEvaluatedInClipLocalTime() throws {
        let c = Self.picture(Time(10, 1))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        var p = AnimatedProperty(Vec2.zero)
        p.track.insert(Keyframe(time: .zero, value: Vec2(0, 0)))
        p.track.insert(Keyframe(time: Time(2, 1), value: Vec2(200, 0)))
        try t.editOverride(clip: c.id, variant: v) { $0.position = p }
        let tr = try #require(t.videoLayers(at: Time(11, 1), variant: v).first).transform
        #expect(abs(tr.position.x - 100) < 1e-9)
    }

    @Test func automaticConformScalesBaseKeysToo() throws {
        var c = Self.picture(pos: .zero)
        c.animation.position.track.insert(Keyframe(time: .zero, value: Vec2(0, 0)))
        c.animation.position.track.insert(Keyframe(time: Time(2, 1), value: Vec2(108, 0)))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        let tr = try #require(t.videoLayers(at: Time(2, 1), variant: v).first).transform
        #expect(abs(tr.position.x - 108 * 1920.0 / 1080.0) < 1e-9)
    }

    @Test func motionOffStillRendersAtDefaultsInAVariant() throws {
        var c = Self.picture()
        c.motionEnabled = false
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(5, 5)) }
        let tr = try #require(t.videoLayers(at: .zero, variant: v).first).transform
        #expect(tr.position == .zero && tr.scale == Vec2(1, 1))
    }

    @Test func textKeepsScaleAndMovesPositionPerAxis() throws {
        let c = Self.text(pos: Vec2(192, 432))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        let tr = try #require(t.videoLayers(at: .zero, variant: v).first).transform
        #expect(tr.scale == Vec2(1, 1))
        #expect(abs(tr.position.x - 192 * 1080.0 / 1920.0) < 1e-9)
        #expect(abs(tr.position.y - 432 * 1920.0 / 1080.0) < 1e-9)
    }

    @Test func textGeneratorOverrideReplacesThePayloadInThatVariantOnly() throws {
        let c = Self.text()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        let boxed = GeneratorRef(kind: GeneratorRef.text, payload: Data([9]), payloadVersion: 3)
        try t.editOverride(clip: c.id, variant: v) { $0.generator = boxed }
        #expect(t.videoLayers(at: .zero, variant: v).first?.generator == boxed)
        #expect(t.videoLayers(at: .zero).first?.generator == c.generator)
    }

    @Test func generatorOverrideOfAnotherKindIsIgnored() throws {
        let c = Self.text()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.generator = GeneratorRef.solid(rgb: [1, 2, 3]) }
        #expect(t.videoLayers(at: .zero, variant: v).first?.generator == c.generator)
    }

    @Test func solidsAreNotConformed() throws {
        let id = UUID()
        var c = Clip(id: id, name: "s", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)),
                     start: .zero, generator: GeneratorRef.solid(rgb: [0, 0, 0]))
        c.animation.scale.value = Vec2(3, 3)
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        #expect(t.videoLayers(at: .zero, variant: v).first?.transform.scale == Vec2(3, 3))
    }

    @Test func effectParameterOverrideAppliesPerVariant() throws {
        var c = Self.picture()
        let crop = ClipEffect(kind: ClipEffect.cropKind, parameters: [ClipEffect.cropLeftKey: AnimatedProperty(10)])
        c.effects = [crop]
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.effectParameters[crop.id] = [ClipEffect.cropLeftKey: AnimatedProperty(30)] }
        let resolved = t.resolvedClip(t.find(c.id)!.clip, variant: v)
        #expect(resolved.effects[0].parameters[ClipEffect.cropLeftKey]?.value == 30)
        #expect(t.find(c.id)!.clip.effects[0].parameters[ClipEffect.cropLeftKey]?.value == 10)
        let base = t.videoLayers(at: .zero).first!.effects
        let variant = t.videoLayers(at: .zero, variant: v).first!.effects
        #expect(base != variant)
    }

    @Test func overrideForADeletedEffectIsIgnored() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.effectParameters[UUID()] = ["x": AnimatedProperty(1)] }
        let resolved = t.resolvedClip(t.find(c.id)!.clip, variant: v)
        #expect(resolved.effects.isEmpty)
    }

    @Test func variantCanvasIsUsedForPairs() throws {
        let a = Self.picture(.zero, Time(2, 1))
        var b = Self.picture(Time(2, 1), Time(2, 1))
        b.source = TimeRange(start: Time(3, 1), duration: Time(2, 1))
        var tr = Track(kind: .video, clips: [a, b])
        tr.transitions = [Transition(kind: .crossDissolve, duration: Time(1, 1), outgoing: a.id, incoming: b.id)]
        var t = Timeline(name: "S", format: Self.base, tracks: [tr])
        let v = try Self.vertical(&t)
        let layers = t.videoLayers(at: Time(2, 1), variant: v)
        #expect(layers.count == 2)
        #expect(layers.allSatisfy { $0.pair?.format.width == 1080 && $0.pair?.format.height == 1920 })
    }

    @Test func nestedClipGetsTheVariantButItsInnerLayersDoNot() throws {
        let innerClip = Self.picture(pos: Vec2(10, 10))
        let inner = Timeline(name: "In", format: Self.base, tracks: [Track(kind: .video, clips: [innerClip])])
        var nest = Self.picture(pos: Vec2(0, 0))
        nest.sequence = inner.id
        nest.media = inner.id
        var t = Self.timeline([nest])
        let v = try Self.vertical(&t)
        let layers = t.videoLayers(at: .zero, sequences: { $0 == inner.id ? inner : nil }, variant: v)
        let l = try #require(layers.first)
        #expect(l.transform.position == Vec2(10, 10))                          // inner layer: base
        #expect(abs(l.groups[0].transform.scale.x - 1920.0 / 1080.0) < 1e-9)   // nested clip: conformed
        #expect(l.groups[0].format == Self.base)
    }

    @Test func unknownVariantEvaluatesAsBase() throws {
        let c = Self.picture()
        let t = Self.timeline([c])
        #expect(t.videoLayers(at: .zero, variant: UUID()) == t.videoLayers(at: .zero))
    }

    @Test func detachCopiesTheAutomaticValueIntoTheOverride() throws {
        var c = Self.picture(pos: Vec2(54, 0), scale: Vec2(1, 1))
        c.animation.scale.track.insert(Keyframe(time: .zero, value: Vec2(1, 1)))
        c.animation.scale.track.insert(Keyframe(time: Time(1, 1), value: Vec2(2, 2)))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        let before = t.videoLayers(at: Time(1, 2), variant: v)
        try t.detach([.position, .scale], clip: c.id, variant: v)
        let o = try #require(t.override(of: c.id, in: v))
        #expect(o.position != nil && o.scale != nil && o.rotation == nil)
        #expect(o.scale?.track.keys.count == 2)
        #expect(t.videoLayers(at: Time(1, 2), variant: v) == before)       // nothing moves on screen
        // Detaching again keeps the edited override.
        try t.editOverride(clip: c.id, variant: v) { $0.position?.value = Vec2(1, 1) }
        try t.detach([.position], clip: c.id, variant: v)
        #expect(t.override(of: c.id, in: v)?.position?.value == Vec2(1, 1))
    }

    @Test func resetRemovesOneOrAllProperties() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.detach(Set(VariantProperty.allCases), clip: c.id, variant: v)
        try t.resetOverride(.position, clip: c.id, variant: v)
        #expect(t.override(of: c.id, in: v)?.position == nil)
        #expect(t.override(of: c.id, in: v)?.scale != nil)
        try t.resetOverride(nil, clip: c.id, variant: v)
        #expect(t.override(of: c.id, in: v) == nil)
    }

    // MARK: Shared edit: overrides follow the clip

    @Test func splitKeepsOverridesOnBothHalvesWithKeysOnTheSameFrames() throws {
        let c = Self.picture(.zero, Time(4, 1))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        var p = AnimatedProperty(Vec2.zero)
        p.track.insert(Keyframe(time: Time(3, 1), value: Vec2(30, 0)))
        try t.editOverride(clip: c.id, variant: v) { $0.position = p }
        try t.tracks[0].split(at: Time(2, 1))
        let right = t.tracks[0].clips[1]
        #expect(right.variantOverrides[v]?.position?.track.keys.first?.time == Time(1, 1))
        #expect(t.tracks[0].clips[0].variantOverrides[v]?.position?.track.keys.first?.time == Time(3, 1))
    }

    @Test func headTrimShiftsOverrideKeys() throws {
        let c = Self.picture(Time(2, 1), Time(4, 1))
        var t = Self.timeline([c])
        t.tracks[0] = Track(kind: .video, clips: [{ var x = c; x.source = TimeRange(start: Time(2, 1), duration: Time(4, 1)); return x }()])
        let v = try Self.vertical(&t)
        var p = AnimatedProperty(0.0)
        p.track.insert(Keyframe(time: Time(1, 1), value: 45))
        try t.editOverride(clip: c.id, variant: v) { $0.rotation = p }
        var clip = t.find(c.id)!.clip
        clip.extendHead(by: Time(1, 1))
        #expect(clip.variantOverrides[v]?.rotation?.track.keys.first?.time == Time(2, 1))
        #expect(clip.animation.rotation.track.isEmpty)
    }

    @Test func rippleEditsMoveTheClipWithItsOverrides() throws {
        let a = Self.picture(.zero, Time(2, 1)), b = Self.picture(Time(2, 1), Time(2, 1))
        var t = Self.timeline([a, b])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: b.id, variant: v) { $0.position = AnimatedProperty(Vec2(-1, -1)) }
        try t.rippleDelete([a.id])
        #expect(t.find(b.id)?.clip.start == .zero)
        #expect(t.override(of: b.id, in: v)?.position?.value == Vec2(-1, -1))
        #expect(t.videoLayers(at: .zero, variant: v).first?.transform.position == Vec2(-1, -1))
    }

    @Test func retimeRescalesOverrideKeys() throws {
        var c = Self.picture()
        var p = AnimatedProperty(0.0)
        p.track.insert(Keyframe(time: Time(2, 1), value: 1))
        c.variantOverrides[UUID()] = VariantOverride(rotation: p)
        let v = c.variantOverrides.keys.first!
        c.rescaleKeys(from: Time(4, 1), to: Time(8, 1), mirror: false)
        #expect(c.variantOverrides[v]?.rotation?.track.keys.first?.time == Time(4, 1))
    }

    @Test func pruneDropsOverridesOfUnknownVariants() throws {
        var c = Self.picture()
        c.variantOverrides[UUID()] = VariantOverride(rotation: AnimatedProperty(1))
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.rotation = AnimatedProperty(2) }
        let first = t.pruneVariantOverrides()
        #expect(first)
        #expect(Array(t.find(c.id)!.clip.variantOverrides.keys) == [v])
        let second = t.pruneVariantOverrides()
        #expect(!second)
    }

    // MARK: Undo snapshots

    @Test func overrideEditsAreOneUndoStepEach() throws {
        let c = Self.picture()
        var p = Project(name: "P", timelines: [Self.timeline([c])])
        let tid = p.timelines[0].id
        var h = History(p)
        var v: FormatVariant.ID!
        try h.commit("Add Variant") { try $0.withTimeline(tid) { v = try $0.addVariant(name: "9:16", width: 1080, height: 1920) } }
        try h.commit("Move") { try $0.withTimeline(tid) { try $0.editOverride(clip: c.id, variant: v) { $0.position = AnimatedProperty(Vec2(9, 9)) } } }
        #expect(h.current.timelines[0].override(of: c.id, in: v)?.position?.value == Vec2(9, 9))
        var ok = h.undo()
        #expect(ok)
        #expect(h.current.timelines[0].override(of: c.id, in: v) == nil)
        #expect(h.current.timelines[0].variants.count == 1)
        ok = h.undo()
        #expect(ok)
        #expect(h.current.timelines[0].variants.isEmpty)
        ok = h.redo() && h.redo()
        #expect(ok)
        #expect(h.current.timelines[0].override(of: c.id, in: v)?.position?.value == Vec2(9, 9))
        p = h.current
        #expect(h.isDirty)
    }

    @Test func withTimelineThrowsForAnUnknownTimeline() {
        var p = Project(name: "P", timelines: [])
        #expect(throws: EditError.timelineNotFound) { try p.withTimeline(UUID()) { _ in } }
    }

    // MARK: File format

    @Test func roundTripKeepsVariantsAndOverrides() throws {
        var c = Self.text()
        let crop = ClipEffect(kind: ClipEffect.cropKind, parameters: [:])
        c.effects = [crop]
        var t = Self.timeline([c])
        let v = try Self.vertical(&t, conform: .fit)
        var pos = AnimatedProperty(Vec2(1, 2))
        pos.track.insert(Keyframe(time: Time(1, 3), value: Vec2(5, 6)))
        try t.editOverride(clip: c.id, variant: v) {
            $0.position = pos
            $0.scale = AnimatedProperty(Vec2(2, 3))
            $0.rotation = AnimatedProperty(4)
            $0.anchor = AnimatedProperty(Vec2(7, 8))
            $0.conform = .fill
            $0.generator = GeneratorRef(kind: GeneratorRef.text, payload: Data([4]), payloadVersion: 2)
            $0.effectParameters[crop.id] = [ClipEffect.cropTopKey: AnimatedProperty(12)]
        }
        let project = Project(name: "P", timelines: [t])
        let back = try ProjectFile.decode(try ProjectFile.encode(project), migrations: ProjectFile.migrations)
        #expect(back == project)
        #expect(back.timelines[0].variants == t.variants)
        #expect(back.timelines[0].override(of: c.id, in: v) == t.override(of: c.id, in: v))
    }

    @Test func overridesAreKeyedByVariantIDStringsInTheFile() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.rotation = AnimatedProperty(1) }
        let text = String(decoding: try ProjectFile.encode(Project(name: "P", timelines: [t])), as: UTF8.self)
        #expect(text.contains("\"\(v.uuidString)\" : {"))
    }

    @Test func currentVersionIs26OrLater() {
        #expect(ProjectFile.currentVersion >= 26)
        #expect(ProjectFile.realMigrations[25] != nil)
    }

    @Test func aV25FileOpensWithoutVariants() throws {
        let c = Self.picture()
        let project = Project(name: "P", timelines: [Self.timeline([c])])
        var obj = try #require(JSONSerialization.jsonObject(with: try ProjectFile.encode(project)) as? [String: Any])
        obj["formatVersion"] = 25
        // A v25 timeline has no `variants` key and clips no `variantOverrides`.
        var p = obj["project"] as! [String: Any]
        p["timelines"] = (p["timelines"] as! [[String: Any]]).map { var t = $0; t["variants"] = nil; return t }
        obj["project"] = p
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].variants.isEmpty)
        #expect(back.timelines[0].tracks[0].clips[0].variantOverrides.isEmpty)
        #expect(back == project)
    }

    @Test func migrationDropsOverridesWhoseVariantIsMissing() throws {
        var c = Self.picture()
        c.variantOverrides[UUID()] = VariantOverride(rotation: AnimatedProperty(1))
        let project = Project(name: "P", timelines: [Self.timeline([c])])
        var obj = try #require(JSONSerialization.jsonObject(with: try ProjectFile.encode(project)) as? [String: Any])
        obj["formatVersion"] = 25
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].variantOverrides.isEmpty)
    }

    @Test func variantDecodingRejectsABadSize() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"x","width":0,"height":10}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FormatVariant.self, from: Data(json.utf8)) }
        let ok = #"{"id":"\#(UUID().uuidString)","name":"x","width":10,"height":10}"#
        #expect(try JSONDecoder().decode(FormatVariant.self, from: Data(ok.utf8)).conform == .fill)
    }

    @Test func duplicateSequenceCarriesVariantsAndOverrides() throws {
        let c = Self.picture()
        var t = Self.timeline([c])
        let v = try Self.vertical(&t)
        try t.editOverride(clip: c.id, variant: v) { $0.rotation = AnimatedProperty(3) }
        var p = Project(name: "P", timelines: [t])
        let copyID = try p.duplicateSequence(t.id, as: Self.base, mode: .fit)
        let copy = try #require(p.timeline(copyID))
        // W5.1: the copy's variants get fresh ids (same names and sizes); overrides follow them.
        #expect(copy.variants.map(\.name) == t.variants.map(\.name))
        let nv = try #require(copy.variants.first?.id)
        #expect(nv != v)
        let cc = try #require(copy.tracks[0].clips.first)
        #expect(cc.id != c.id)
        #expect(copy.override(of: cc.id, in: nv)?.rotation?.value == 3)
    }
}
