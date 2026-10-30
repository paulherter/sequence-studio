import Foundation
import Testing
import SQCore
@testable import SQLibrary

@Suite struct PresetFileTests {
    /// Pop-in: Scale and Opacity keys with ease, plus an effect.
    private func popIn() throws -> (EffectPreset, PresetItem) {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        c.animation.scale.track = KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(0, 0), interpolation: .bezier, outHandle: EaseHandle(dx: 0.6, dy: 0)),
            Keyframe(time: Time(1, 2), value: Vec2(1.1, 1.1), interpolation: .bezier, inHandle: EaseHandle(dx: 0.37, dy: 0.1)),
        ])
        c.animation.opacity.track = KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(1001, 3000), value: 0.95),
        ])
        c.effects = [ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(0.1)])]
        let preset = EffectPreset.capture(from: c, anchor: .stretch)
        let item = PresetItem(kind: .effect, name: "Pop In", createdAt: Date(timeIntervalSince1970: 5),
                              payload: try preset.payload(), payloadVersion: EffectPreset.payloadVersion)
        return (preset, item)
    }

    @Test func effectPresetRoundTripsThroughFile() throws {
        let (preset, item) = try popIn()
        let data = try PresetFile.encode(item)
        let back = try PresetFile.decode(data)
        #expect(back.kind == .effect && back.name == "Pop In" && back.payloadVersion == EffectPreset.payloadVersion)
        #expect(back.id != item.id)                       // an import is a new preset
        #expect(try EffectPreset(payload: back.payload, version: back.payloadVersion) == preset)
    }

    @Test func fileIsReadableVersionedJSON() throws {
        let (_, item) = try popIn()
        let obj = try JSONSerialization.jsonObject(with: try PresetFile.encode(item)) as? [String: Any]
        #expect(obj?["format"] as? String == PresetFile.formatName)
        #expect(obj?["formatVersion"] as? Int == PresetFile.formatVersion)
        #expect(obj?["kind"] as? String == "effect")
        #expect(obj?["payload"] is [String: Any])          // embedded object, not base64
    }

    @Test func rejectsForeignNewerAndBrokenFiles() throws {
        #expect(throws: PresetFileError.notAPreset) { try PresetFile.decode(Data("{\"a\":1}".utf8)) }
        #expect(throws: PresetFileError.notAPreset) { try PresetFile.decode(Data("nope".utf8)) }
        let newer = #"{"format":"\#(PresetFile.formatName)","formatVersion":99,"kind":"effect","name":"x","payloadVersion":1,"payload":{}}"#
        #expect(throws: LibraryStoreError.newerFormat(found: 99, supported: PresetFile.formatVersion)) {
            try PresetFile.decode(Data(newer.utf8))
        }
        let unknownKind = #"{"format":"\#(PresetFile.formatName)","formatVersion":1,"kind":"hologram","name":"x","payloadVersion":1,"payload":{}}"#
        #expect(throws: PresetFileError.unknownKind("hologram")) { try PresetFile.decode(Data(unknownKind.utf8)) }
    }

    @Test func storeExportsAndImports() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        let (preset, item) = try popIn()
        try await store.add(item)
        let file = dir.url.appendingPathComponent("Pop In.sqpreset")
        try await store.exportPreset(item.id, to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let other = try TempDir(); defer { other.remove() }
        let store2 = try PresetStore(applicationSupport: other.url)
        let imported = try await store2.importPreset(from: file)
        #expect(await store2.all().map(\.id) == [imported.id])
        #expect(try EffectPreset(payload: imported.payload, version: imported.payloadVersion) == preset)
        // Persisted.
        let reopened = try PresetStore(applicationSupport: other.url)
        #expect(await reopened.all().map(\.name) == ["Pop In"])
        await #expect(throws: LibraryStoreError.notFound) { try await store.exportPreset(UUID(), to: file) }
    }

    @Test func effectPayloadIsValidatedOnImport() throws {
        let newer = #"{"format":"\#(PresetFile.formatName)","formatVersion":1,"kind":"effect","name":"x","payloadVersion":99,"payload":{}}"#
        #expect(throws: LibraryStoreError.newerFormat(found: 99, supported: EffectPreset.payloadVersion)) {
            try PresetFile.decode(Data(newer.utf8))
        }
        let garbage = #"{"format":"\#(PresetFile.formatName)","formatVersion":1,"kind":"effect","name":"x","payloadVersion":1,"payload":{"anchor":42}}"#
        #expect(throws: PresetFileError.damagedPayload) { try PresetFile.decode(Data(garbage.utf8)) }
        // Other kinds stay opaque to the file layer.
        let text = #"{"format":"\#(PresetFile.formatName)","formatVersion":1,"kind":"textTemplate","name":"x","payloadVersion":1,"payload":{}}"#
        #expect(try PresetFile.decode(Data(text.utf8)).kind == .textTemplate)
    }

    @Test func transitionPresetRoundTripsThroughFileAndStore() async throws {
        let preset = TransitionPreset(kind: .whip, duration: Time(6, 30), alignment: .endAtCut, easing: .fastStart,
                                      direction: .up, softness: 0.2, motionBlur: 1)
        let item = PresetItem(kind: .transition, name: "Quick whip", payload: try preset.payload(),
                              payloadVersion: TransitionPreset.payloadVersion)
        let back = try PresetFile.decode(try PresetFile.encode(item))
        #expect(back.kind == .transition)
        #expect(try TransitionPreset(payload: back.payload, version: back.payloadVersion) == preset)
        let dir = try TempDir(); defer { dir.remove() }
        let store = try PresetStore(applicationSupport: dir.url)
        try await store.add(item)
        let reopened = try PresetStore(applicationSupport: dir.url)
        let saved = await reopened.presets(kind: .transition)
        #expect(saved.map(\.name) == ["Quick whip"])
        #expect(try TransitionPreset(payload: saved[0].payload, version: saved[0].payloadVersion) == preset)
        #expect(await reopened.presets(kind: .effect).isEmpty)
    }

    @Test func transitionPayloadIsValidatedOnImport() throws {
        let newer = #"{"format":"\#(PresetFile.formatName)","formatVersion":1,"kind":"transition","name":"x","payloadVersion":99,"payload":{}}"#
        #expect(throws: LibraryStoreError.newerFormat(found: 99, supported: TransitionPreset.payloadVersion)) {
            try PresetFile.decode(Data(newer.utf8))
        }
        let garbage = #"{"format":"\#(PresetFile.formatName)","formatVersion":1,"kind":"transition","name":"x","payloadVersion":1,"payload":{"kind":"nope"}}"#
        #expect(throws: PresetFileError.damagedPayload) { try PresetFile.decode(Data(garbage.utf8)) }
    }

    @Test func storeImportRejectsBadPayloadWithoutAdding() async throws {
        let dir = try TempDir(); defer { dir.remove() }
        let file = dir.url.appendingPathComponent("bad.sqpreset")
        try Data(#"{"format":"\#(PresetFile.formatName)","formatVersion":1,"kind":"effect","name":"x","payloadVersion":1,"payload":[]}"#.utf8).write(to: file)
        let store = try PresetStore(applicationSupport: dir.url)
        await #expect(throws: PresetFileError.damagedPayload) { try await store.importPreset(from: file) }
        #expect(await store.all().isEmpty)
    }

    @Test func suggestedFileNameIsSafe() {
        #expect(PresetFile.suggestedFileName(for: "Pop/In: fast") == "Pop-In- fast.sqpreset")
        #expect(PresetFile.suggestedFileName(for: "  ") == "Preset.sqpreset")
    }

    /// Parameter values and key times/values, without key ids.
    private func shape(_ e: ClipEffect) -> [String: [Double]] {
        e.parameters.mapValues { p in [p.value] + p.track.keys.flatMap { [Double($0.time.value) / Double($0.time.timescale), $0.value] } }
    }

    /// W7.5: Save as Preset keeps a Transform stage with its parameters; on another clip it bakes and re-opens.
    @Test func transformStagePresetSurvivesFileApplyBakeAndReopen() throws {
        var src = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var fx = try #require(ClipEffect.make(kind: ClipEffect.transformKind))
        fx.parameters[ClipEffect.stageScaleKey] = AnimatedProperty(100, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 100), Keyframe(time: Time(1, 2), value: 115),
        ]))
        fx.parameters[ClipEffect.stageRotationKey] = AnimatedProperty(5)
        src.effects = [fx]
        let item = PresetItem(kind: .effect, name: "Punch", payload: try EffectPreset.capture(from: src).payload(),
                              payloadVersion: EffectPreset.payloadVersion)
        let back = try PresetFile.decode(try PresetFile.encode(item))
        let preset = try EffectPreset(payload: back.payload, version: back.payloadVersion)

        var target = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                          start: .zero)
        target.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        target.applyPreset(preset, mode: .relative)
        let live = try #require(target.effects.first)
        #expect(shape(live) == shape(fx))   // key ids are fresh on apply

        try target.convertToKeyframes(effect: live.id, frameDuration: Time(1, 30), frame: Vec2(1920, 1080))
        #expect(target.effects.isEmpty && target.animation.scale.isAnimated)
        try target.reopenAsEffect(try #require(target.bakedEffects.first).id)
        #expect(target.effects.first.map(shape) == shape(fx))
        #expect(target.animation.scale == AnimatedProperty(Vec2(1.2, 1.2)))
    }
}
