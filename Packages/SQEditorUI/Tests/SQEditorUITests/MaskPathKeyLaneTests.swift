import Foundation
import Testing
import SQAnalysis
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

/// Mask keys in the keyframe lanes: a path mask's Path keys and a Magic mask's tracked frames.
@MainActor @Suite struct MaskPathKeyLaneTests {
    final class Log { var edits: [(Clip, String)] = [] }

    /// Clip at 5 s, 10 s long, source from 0. Path keys at local 1 s and 3 s.
    func pathRig() -> (EffectControlsModel, ClipMask.ID, Log) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let mask = ClipMask.make(.rectangle, name: "Mask (1)")
        clip.masks = [mask]
        let m = EffectControlsModel(); let log = Log()
        m.magicFrames = MagicTrackedFrames(store: MagicMatteStore(directory: nil), loadsInBackground: false)
        m.onEdit = { c, n, _ in log.edits.append((c, n)) }
        m.setClip(clip)
        m.playhead = Time(6, 1)
        m.setMaskPathAnimated(mask.id, true)
        m.playhead = Time(8, 1)
        m.toggleMaskPathKeyAtPlayhead(mask.id)
        return (m, mask.id, log)
    }

    private func matte() -> SubjectMatte { SubjectMatte(width: 2, height: 2, values: [0, 1, 1, 0]) }

    /// Magic mask with a correction point at source 2 s; tracked frames at source 1, 2, 3 and 20 s (20 is outside).
    func magicRig() -> (EffectControlsModel, ClipMask.ID, MagicTrackedFrames, String, Log) {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let points = [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero),
                      MagicPoint(position: Vec2(0.4, 0.4), subtract: false, sourceTime: Time(2, 1))]
        let mask = ClipMask.makeMagic(name: "Magic", points: points)
        clip.masks = [mask]
        let store = MagicMatteStore(directory: nil)
        let key = mask.magic!.cacheKey(media: clip.media)
        for s in [1.0, 2.0, 3.0, 20.0] { store.put(matte(), key: key, pts: s) }
        let frames = MagicTrackedFrames(store: store, loadsInBackground: false)
        let m = EffectControlsModel(); let log = Log()
        m.magicFrames = frames
        m.onEdit = { c, n, _ in log.edits.append((c, n)) }
        m.setClip(clip)
        m.playhead = Time(5, 1)
        return (m, mask.id, frames, key, log)
    }

    // MARK: Path keys

    @Test func pathKeysShowInTheLaneSummaryAndMarquee() {
        let (m, id, _) = pathRig()
        let p = EffectProperty.maskPath(id)
        #expect(m.laneKeys(p).map(\.time) == [Time(1, 1), Time(3, 1)])
        #expect(m.summaryKeys(.mask(id)).map(\.time) == [Time(1, 1), Time(3, 1)])
        #expect(m.keys(in: Time(0, 1) ... Time(2, 1), properties: [p]).count == 1)
        #expect(!p.hasGraph && p.title == "Mask Path")
        #expect(EffectProperty(rawValue: p.rawValue) == p)
        #expect(!m.panelProperties.contains(p))
        let lanes = KeyLanes.keyTimes(clip: m.clip!, section: .mask(id))
        #expect(lanes == [Time(6, 1), Time(8, 1)])
    }

    @Test func pathKeysMoveEaseAndDeleteAsOneEditEach() throws {
        let (m, id, log) = pathRig()
        let p = EffectProperty.maskPath(id)
        let first = try #require(m.laneKeys(p).first)
        m.selectKey(p, id: first.id, extend: false)
        m.moveSelection(by: Time(1, 1))
        #expect(m.clip!.mask(id)!.path.track.keys.map(\.time).sorted() == [Time(2, 1), Time(3, 1)])

        m.selectKey(p, id: first.id, extend: false)
        m.toggleHold()
        #expect(log.edits.last?.1 == "Toggle Hold Keyframes")
        #expect(m.clip!.mask(id)!.path.track.key(id: first.id)?.interpolation == .hold)

        let before = m.clip!
        m.selectKey(p, id: first.id, extend: false)
        m.deleteSelection()
        #expect(log.edits.last?.1 == "Delete Keyframes")
        #expect(m.clip!.mask(id)!.path.track.keys.count == 1)
        #expect(before.mask(id)!.path.track.keys.count == 2)     // the old snapshot is the undo state
    }

    @Test func pathKeysCopyAndPasteOntoThePath() throws {
        let (m, id, _) = pathRig()
        let p = EffectProperty.maskPath(id)
        let first = try #require(m.laneKeys(p).first)
        m.selectKey(p, id: first.id, extend: false)
        #expect(m.copyKeys())
        m.playhead = Time(10, 1)
        #expect(m.pasteKeys())
        #expect(m.clip!.mask(id)!.path.track.keys.count == 3)
    }

    @Test func pathStopwatchOffAsksFirst() {
        let (m, id, _) = pathRig()
        #expect(m.toggleStopwatch(.maskPath(id)) == .needsConfirmation)
        #expect(m.clip!.mask(id)!.path.isAnimated)
        #expect(m.toggleStopwatch(.maskPath(id), confirmRemoval: true) == .removed)
        #expect(!m.clip!.mask(id)!.path.isAnimated)
    }

    @Test func removedMaskDropsItsPathSelection() throws {
        let (m, id, _) = pathRig()
        let p = EffectProperty.maskPath(id)
        m.selectKey(p, id: try #require(m.laneKeys(p).first).id, extend: false)
        m.forgetRemovedMasks([id])
        #expect(m.selection.isEmpty)
    }

    // MARK: Magic mask tracked frames

    @Test func trackedFramesMapToClipTimeAndMarkCorrections() {
        let (m, id, _, _, _) = magicRig()
        let keys = m.magicKeys(id)
        #expect(keys.map(\.time) == [Time(1, 1), Time(2, 1), Time(3, 1)])      // 20 s lies outside the clip
        #expect(keys.map(\.isCorrection) == [false, true, false])
        #expect(m.summaryKeys(.mask(id)).count == 3)
        #expect(m.laneKeys(.maskPath(id)).count == 3)
    }

    @Test func timelineLaneShowsTrackedFrames() {
        let (m, id, frames, _, _) = magicRig()
        let old = KeyLanes.magicFrames
        KeyLanes.magicFrames = frames
        defer { KeyLanes.magicFrames = old }
        #expect(KeyLanes.keyTimes(clip: m.clip!, section: .mask(id), frameDuration: m.frameDuration)
                == [Time(6, 1), Time(7, 1), Time(8, 1)])
    }

    @Test func trackedFramesFollowATrimmedClip() {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: Time(2, 1), duration: Time(5, 1)), start: .zero)
        let mask = ClipMask.makeMagic(name: "M", points: [MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: Time(3, 1))])
        clip.masks = [mask]
        let keys = MagicFrameKey.keys(clip: clip, mask: mask, times: [1, 2.5, 3, 6.9, 7], frameDuration: Time(1, 30))
        #expect(keys.map(\.time) == [Time(15, 30), Time(1, 1), Time(147, 30)])
        #expect(keys.map(\.isCorrection) == [false, false, false])     // 3 s is the pick's own frame, not a correction
    }

    /// A correction point stored at the playhead's time inside a source frame belongs to that frame.
    @Test func aCorrectionPointInsideAFrameMarksThatFrame() {
        var clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let mask = ClipMask.makeMagic(name: "M", points: [
            MagicPoint(position: Vec2(0.5, 0.5), subtract: false, sourceTime: .zero),
            MagicPoint(position: Vec2(0.4, 0.4), subtract: true, sourceTime: Time(31, 30))])     // 24 fps file, 30 fps sequence
        clip.masks = [mask]
        let keys = MagicFrameKey.keys(clip: clip, mask: mask, times: [0, 1, 1 + 1.0 / 24, 1 + 2.0 / 24], frameDuration: Time(1, 30))
        #expect(keys.map(\.isCorrection) == [false, true, false, false])
    }

    /// Deleting every tracked frame, the pick's own included, keeps the pick points: Track can start again.
    @Test func deletingAllTrackedFramesKeepsThePickPoints() throws {
        let (m, id, frames, key, _) = magicRig()
        frames.store.put(matte(), key: key, pts: 0)
        frames.forget()
        let keys = m.magicKeys(id)
        #expect(keys.map(\.isCorrection) == [false, false, true, false])
        m.select(keys.map { SummaryMember(property: EffectProperty.maskPath(id).id, keyID: $0.id) }, extend: false)
        m.deleteSelection()
        let points = try #require(m.clip!.mask(id)?.magic?.points)
        #expect(points.map(\.sourceTime) == [.zero])
        #expect(m.clip!.mask(id)?.magic?.anchorTime == .zero)
    }

    @Test func trackedFramesAreSelectableButNotMovable() throws {
        let (m, id, _, _, _) = magicRig()
        let k = try #require(m.magicKeys(id).first)
        m.selectKey(.maskPath(id), id: k.id, extend: false)
        #expect(m.selection.count == 1)
        #expect(m.moveSelection(by: Time(1, 1)) == .zero)
        m.playhead = Time(7, 1)                  // a clip refresh keeps the tracked-frame selection
        m.setClip(m.clip)
        #expect(m.selection.count == 1)
    }

    @Test func deletingTrackedFramesRemovesMattesAndCorrectionPoints() throws {
        let (m, id, frames, key, log) = magicRig()
        let keys = m.magicKeys(id)
        m.select(keys.map { SummaryMember(property: EffectProperty.maskPath(id).id, keyID: $0.id) }.prefix(2).map { $0 }, extend: false)
        m.deleteSelection()
        // The plain frame at 1 s left the store; the correction frame at 2 s lost its point instead.
        #expect(frames.store.times(key: key) == [2, 3, 20])
        #expect(log.edits.last?.1 == "Delete Keyframes")
        let points = try #require(m.clip!.mask(id)?.magic?.points)
        #expect(points.map(\.sourceTime) == [.zero])
        #expect(m.selection.isEmpty)
    }

    /// Deleting plain tracked frames changes no project state: they get their own undo step; one Undo brings them back,
    /// Redo deletes them again, and a project edit in between keeps the order.
    @Test func deletingTrackedFramesIsUndoable() throws {
        let (m, id, frames, key, _) = magicRig()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = EditorSession(project: EditorSession.makeUntitled(), engine: StubProgramEngine(),
                                    autosaveStore: AutosaveStore(base: dir))
        m.speedSession = session
        let plain = m.magicKeys(id).filter { !$0.isCorrection }
        m.select(plain.prefix(1).map { SummaryMember(property: EffectProperty.maskPath(id).id, keyID: $0.id) }, extend: false)
        #expect(!session.canUndo)
        m.deleteSelection()
        #expect(frames.store.times(key: key) == [2, 3, 20])
        #expect(session.canUndo && session.undoName == "Delete Keyframes")
        #expect(session.undo())
        #expect(frames.store.times(key: key) == [1, 2, 3, 20])
        #expect(frames.times(key: key) == [1, 2, 3, 20])
        #expect(!session.canUndo && session.canRedo)
        #expect(session.redo())
        #expect(frames.store.times(key: key) == [2, 3, 20])
        #expect(frames.times(key: key) == [2, 3, 20])
    }

    /// A tracked frame deleted in the middle of a key drag is part of the drag's one undo step, and a canceled drag
    /// brings it back.
    @Test func deletingTrackedFramesDuringAKeyDragIsOneStep() throws {
        let (m, id, frames, key, _) = magicRig()
        var clip = try #require(m.clip)
        clip.animation.scale.track = KeyframeTrack(keys: [Keyframe(time: Time(1, 1), value: Vec2(1, 1)),
                                                          Keyframe(time: Time(4, 1), value: Vec2(2, 2))])
        m.setClip(clip)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = EditorSession(project: EditorSession.makeUntitled(), engine: StubProgramEngine(),
                                    autosaveStore: AutosaveStore(base: dir))
        m.speedSession = session
        let scale = try #require(m.clip?.animation.scale.track.keys.first)
        let plain = try #require(m.magicKeys(id).first { !$0.isCorrection })
        m.select([SummaryMember(property: EffectProperty.scale.id, keyID: scale.id)], extend: false)
        let depth = session.undoStepDepth
        m.beginGesture()
        _ = m.moveSelection(by: Time(1, 1))
        m.select([SummaryMember(property: EffectProperty.maskPath(id).id, keyID: plain.id)], extend: false)
        m.deleteSelection()
        #expect(frames.store.times(key: key) == [2, 3, 20])
        #expect(session.undoStepDepth == depth)               // nothing registered mid drag
        m.endKeyMove()
        #expect(session.undoStepDepth == depth + 1)
        #expect(session.undo())
        #expect(frames.store.times(key: key) == [1, 2, 3, 20])
        #expect(session.undoStepDepth == depth)
    }

    @Test func navigationStepsThroughTrackedFrames() {
        let (m, id, _, _, _) = magicRig()
        var seeks: [Time] = []
        m.onSeek = { seeks.append($0) }
        m.playhead = Time(5, 1)
        m.goToNextMaskRowKey(id)
        #expect(seeks.last == Time(6, 1))
        m.playhead = Time(7, 1)
        m.goToNextMaskRowKey(id)
        #expect(seeks.last == Time(8, 1))
        m.goToPreviousMaskRowKey(id)
        #expect(seeks.last == Time(6, 1))
        #expect(m.maskRowKeyframeState(id) == KeyframeControlState.resolve(animated: true, onKey: true, hasPrevious: true,
                                                                            hasNext: true, playheadInRange: true))
    }

    @Test func removeFramesKeepsTheCacheInStep() {
        let store = MagicMatteStore(directory: nil)
        for s in [1.0, 2.0] { store.put(matte(), key: "k", pts: s) }
        let f = MagicTrackedFrames(store: store, loadsInBackground: false)
        #expect(f.times(key: "k") == [1, 2])
        let r = f.revision
        f.remove(key: "k", times: [1])
        #expect(f.times(key: "k") == [2] && f.revision > r)
        store.put(matte(), key: "k", pts: 5)
        #expect(f.times(key: "k") == [2])        // served from memory until forgotten
        f.forget()
        #expect(f.times(key: "k") == [2, 5])
    }
}
