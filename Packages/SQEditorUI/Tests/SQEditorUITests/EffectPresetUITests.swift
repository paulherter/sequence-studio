import AppKit
import Foundation
import Testing
import SQCore
import SQLibrary
@testable import SQEditorUI
@testable import SQInspectorUI

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func ms(_ n: Int64) -> Time { Time(n, 1000) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}
@MainActor private func makeSession(_ tracks: [Track]) -> EditorSession {
    EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: tracks)]),
                  engine: StubProgramEngine())
}

/// Scale + Opacity pop-in over 500 ms with ease out.
private func popIn(_ c: Clip) -> Clip {
    var c = c
    let ease = EaseHandle(dx: 0.6, dy: 0)
    c.animation.scale.track = KeyframeTrack(keys: [
        Keyframe(time: .zero, value: Vec2(0, 0), interpolation: .bezier, outHandle: ease),
        Keyframe(time: ms(500), value: Vec2(1, 1), interpolation: .bezier)])
    c.animation.opacity.track = KeyframeTrack(keys: [
        Keyframe(time: .zero, value: 0.0, interpolation: .bezier, outHandle: ease),
        Keyframe(time: ms(500), value: 1.0)])
    return c
}

@MainActor @Suite struct EffectPresetUITests {
    // MARK: Context menu

    @Test func saveAsPresetNeedsExactlyOneVideoClip() {
        let v = clip(0, 4), v2 = clip(4, 4), a = clip(0, 4, kind: .audio)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [track([v, v2]), track([a], kind: .audio)])
        func on(_ sel: Set<Clip.ID>) -> Bool {
            TimelineContextMenu.items(timeline: tl, selection: sel, clipboardHasClips: false)
                .first { $0.action == .saveAsPreset }?.isEnabled ?? false
        }
        #expect(on([v.id]))
        #expect(!on([a.id]))
        #expect(!on([v.id, v2.id]))
        #expect(!on([]))
        #expect(TimelineContextMenu.items(timeline: tl, selection: [v.id], clipboardHasClips: false)
            .contains { $0.title == "Save as Preset…" })
    }

    // MARK: Session

    @Test func savedPopInAppliesToShortAndLongClipsInOneUndoStep() throws {
        let src = popIn(clip(0, 4)), short = clip(4, 2), long = clip(6, 10)
        let ses = makeSession([track([src, short, long])])
        ses.select(clips: [src.id])
        let preset = try #require(ses.presetFromSelectedClip(anchor: .start))
        let item = try EditorSession.effectPresetItem(name: "Pop In", preset: preset)
        #expect(item.kind == .effect && item.payloadVersion == EffectPreset.payloadVersion)

        #expect(ses.applyPreset(item, to: [short.id, long.id]))
        let clips = ses.activeTimeline!.tracks[0].clips
        for c in clips where c.id != src.id {
            #expect(c.animation.scale.track.keys.map(\.time) == [.zero, ms(500)])
            #expect(c.animation.opacity.track.keys.map(\.time) == [.zero, ms(500)])
            #expect(c.animation.scale.track.keys[0].outHandle == EaseHandle(dx: 0.6, dy: 0))
        }
        #expect(ses.undoName == "Apply Preset “Pop In”")
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips.filter { $0.id != src.id }.allSatisfy { $0.animation.scale.track.isEmpty })
    }

    @Test func untouchedClipGivesNoPresetAndNonEffectItemsAreRefused() throws {
        let c = clip(0, 4)
        let ses = makeSession([track([c])])
        ses.select(clips: [c.id])
        #expect(ses.presetFromSelectedClip(anchor: .start) == nil)
        let text = PresetItem(kind: .textTemplate, name: "T", payload: Data("{}".utf8), payloadVersion: 1)
        #expect(!ses.applyPreset(text, to: [c.id]))
    }

    @Test func applyWithoutTargetsUsesTheSelection() throws {
        let src = popIn(clip(0, 4)), other = clip(4, 2)
        let ses = makeSession([track([src, other])])
        ses.select(clips: [src.id])
        let item = try EditorSession.effectPresetItem(name: "P", preset: ses.presetFromSelectedClip(anchor: .start)!)
        ses.select(clips: [other.id])
        #expect(ses.applyPreset(item))
        #expect(ses.activeTimeline!.tracks[0].clips[1].animation.opacity.track.keys.count == 2)
    }

    @Test func linkedVideoClipCanBeSavedAsPreset() throws {
        let link = UUID()
        var v = popIn(clip(0, 4)); v.link = link
        var a = clip(0, 4, kind: .audio); a.link = link
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [track([v]), track([a], kind: .audio)])
        let item = TimelineContextMenu.items(timeline: tl, selection: [v.id, a.id], clipboardHasClips: false)
            .first { $0.action == .saveAsPreset }
        #expect(item?.isEnabled == true)
        let ses = makeSession([track([v]), track([a], kind: .audio)])
        ses.select(clips: [v.id, a.id])
        #expect(ses.presetFromSelectedClip(anchor: .start)?.motionProperties == [.scale, .opacity])
    }

    @Test func noOpApplyIsNotAFailure() throws {
        let c = clip(0, 4)
        let ses = makeSession([track([c])])
        let empty = try EditorSession.effectPresetItem(name: "Empty", preset: EffectPreset(referenceDuration: s(1)))
        #expect(ses.applyPreset(empty, to: [c.id]))
        #expect(ses.lastError == nil)
        // A real failure still reports, with a fresh message.
        let text = PresetItem(kind: .textTemplate, name: "T", payload: Data("{}".utf8), payloadVersion: 1)
        #expect(!ses.applyPreset(text, to: [c.id]))
        #expect(ses.lastError?.contains("not an effect preset") == true)
    }

    // MARK: Drop

    @Test func presetDropIDRoundTrips() {
        let id = UUID()
        let effectID = PresetDrop.effectID(for: id)
        #expect(PresetDrop.presetID(fromEffectID: effectID) == id)
        #expect(PresetDrop.presetID(fromEffectID: ClipEffect.gaussianBlurKind) == nil)
        #expect(EffectsPanelView.transitionKind(forID: effectID) == nil)
    }

    // MARK: Library

    @Test func libraryModelSavesExportsImportsAndDeletesPresets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("presetui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PresetStore(applicationSupport: root.appendingPathComponent("support"))
        let model = LibraryPanelModel(
            index: LibraryIndex(watcher: FakeFolderWatcher()), presetStore: store,
            coordinator: PreviewCoordinator(cache: PreviewCache(cachesDirectory: root.appendingPathComponent("c"), disk: .unchecked), provider: MediaPreviewProvider(cache: PreviewCache(cachesDirectory: root.appendingPathComponent("c"), disk: .unchecked))),
            favoritesURL: root.appendingPathComponent("fav.json"))
        await model.start()
        let preset = EffectPreset.capture(from: popIn(clip(0, 4)))
        let item = try EditorSession.effectPresetItem(name: "Pop In", preset: preset)
        try await model.savePreset(item)
        #expect(model.presets.map(\.id) == [item.id])
        model.selection = .presets(.effect)
        #expect(model.visiblePresets.map(\.name) == ["Pop In"])

        let file = root.appendingPathComponent(PresetFile.suggestedFileName(for: item.name))
        try await model.exportPreset(item.id, to: file)
        await model.deletePreset(item.id)
        #expect(model.presets.isEmpty)
        let failures = await model.importPresets(from: [file, root.appendingPathComponent("missing.sqpreset")])
        #expect(failures.count == 1)
        #expect(model.presets.map(\.name) == ["Pop In"])
        let back = model.presets[0]
        #expect(try EffectPreset(payload: back.payload, version: back.payloadVersion) == preset)
    }

    /// Easing presets (curve popover) and the Library panel share one store: an easing save is not overwritten by a
    /// later Library write, and both survive a reload from disk.
    @Test func easingAndLibrarySavesShareOneStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("presetshare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let store = try PresetStore(applicationSupport: support)
        let easing = EasingPresetLibrary(store: store)
        let model = LibraryPanelModel(
            index: LibraryIndex(watcher: FakeFolderWatcher()), presetStore: store,
            coordinator: PreviewCoordinator(cache: PreviewCache(cachesDirectory: root.appendingPathComponent("c"), disk: .unchecked), provider: MediaPreviewProvider(cache: PreviewCache(cachesDirectory: root.appendingPathComponent("c"), disk: .unchecked))),
            favoritesURL: root.appendingPathComponent("fav.json"))
        await model.start()
        try await easing.save(.linear, name: "Mine")
        let item = try EditorSession.effectPresetItem(name: "Pop In", preset: EffectPreset.capture(from: popIn(clip(0, 4))))
        try await model.savePreset(item)
        try await easing.save(.hold, name: "Step")
        await model.reloadPresets()
        #expect(Set(model.presets.map(\.name)) == ["Mine", "Pop In", "Step"])
        #expect(easing.saved.map(\.name) == ["Mine", "Step"])
        let reopened = try PresetStore(applicationSupport: support)
        #expect(Set(await reopened.all().map(\.name)) == ["Mine", "Pop In", "Step"])
    }
}
