import AppKit
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

/// WP-H: keyframe controls, modifiers and empty states of the Color page.
@MainActor @Suite(.serialized) struct ColorKeyframeControlTests {
    func rig() throws -> (EditorSession, ColorInspectorPanelView, Clip) {
        let media = UUID()
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v, Track(kind: .audio)])
        var p = Project(name: "P", timelines: [t])
        p.media = [MediaRef(id: media, name: "A", path: "/nonexistent/A.mp4", fingerprint: MediaFingerprint(size: 1),
                            info: MediaInfo(duration: Time(2, 1)))]
        let session = EditorSession(project: p, engine: StubProgramEngine())
        session.select(clips: [clip.id])
        return (session, ColorInspectorPanelView(session: session), clip)
    }

    func current(_ s: EditorSession, _ id: Clip.ID) -> Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == id }! }

    @Test func everyParameterHasAKeyAndAName() {
        var keys = Set<String>()
        for p in ColorParam.allCases {
            keys.insert(p.parameterKey)
            #expect(!p.keyframeName.isEmpty)
        }
        #expect(keys.count == ColorParam.allCases.count)
        #expect(ColorParam.lookIntensity.keyframeName != ColorParam.inputLUTIntensity.keyframeName)
        #expect(ColorWheelSlot.shadows.parameterKeys.count == 3)
        #expect(ColorWheelSlot.shadowTint.parameterKeys.count == 2)
        #expect(ColorKeyTarget.wheel(.midtones).name.hasSuffix("Wheel"))
    }

    @Test func animateKeyAndStopMakeNamedUndoSteps() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        let id = ColorKeyID(effect: 1, target: .param(.exposure))
        let name = ColorParam.exposure.keyframeName

        model.keyframe(.toggleAnimation, 1, .param(.exposure))
        #expect(session.undoName == "Animate \(name)")
        #expect(current(session, clip.id).isColorAnimated(effect: 1, keys: [ColorParam.exposure.parameterKey]))
        #expect(model.keyframeState(1, .param(.exposure)) != .off)

        session.seek(to: Time(1, 1))
        panel.sync([.playhead])
        model.keyframe(.toggleKey, 1, .param(.exposure))
        #expect(session.undoName == "Add \(name) Keyframe")
        #expect(current(session, clip.id).colorKeyTimes(effect: 1, keys: [ColorParam.exposure.parameterKey]) == [.zero, Time(1, 1)])

        model.keyframe(.previous, 1, .param(.exposure))
        #expect(session.playhead == .zero)
        model.keyframe(.next, 1, .param(.exposure))
        #expect(session.playhead == Time(1, 1))
        model.keyframe(.toggleKey, 1, .param(.exposure))
        #expect(session.undoName == "Remove \(name) Keyframe")

        let saved = ColorInspectorPanelView.confirmStopAnimating
        defer { ColorInspectorPanelView.confirmStopAnimating = saved }
        ColorInspectorPanelView.confirmStopAnimating = { _ in false }
        model.keyframe(.toggleAnimation, 1, .param(.exposure))
        #expect(session.undoName == "Remove \(name) Keyframe")          // declined: nothing changed
        ColorInspectorPanelView.confirmStopAnimating = { _ in true }
        model.keyframe(.toggleAnimation, 1, .param(.exposure))
        #expect(session.undoName == "Stop Animating \(name)")
        #expect(!current(session, clip.id).isColorAnimated(effect: 1, keys: [ColorParam.exposure.parameterKey]))
        #expect(model.keyframeStates[id] == nil)
    }

    @Test func wheelKeysAllItsParameters() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.keyframe(.toggleAnimation, 1, .wheel(.shadows))
        #expect(session.undoName == "Animate \(ColorKeyTarget.wheel(.shadows).name)")
        let c = current(session, clip.id)
        for k in ColorWheelSlot.shadows.parameterKeys { #expect(c.isColorAnimated(effect: 1, keys: [k])) }
    }

    @Test func sliderDragModifiers() {
        let plain = LumetriSlider.dragValue(anchor: 0, deltaX: 10, trackWidth: 100, min: -100, max: 100, step: 0.1,
                                            shift: false, option: false)
        let coarse = LumetriSlider.dragValue(anchor: 0, deltaX: 10, trackWidth: 100, min: -100, max: 100, step: 0.1,
                                             shift: true, option: false)
        let fine = LumetriSlider.dragValue(anchor: 0, deltaX: 10, trackWidth: 100, min: -100, max: 100, step: 0.1,
                                           shift: false, option: true)
        #expect(plain > 0 && coarse > plain && fine < plain && fine > 0)
        #expect(LumetriSlider.dragValue(anchor: 90, deltaX: 100, trackWidth: 100, min: -100, max: 100, step: 0.1,
                                        shift: true, option: false) == 100)
        #expect(ColorWheelControl.isFine([.option]) && !ColorWheelControl.isFine([.shift]))
    }

    @Test func emptyStatesNameWhatIsMissing() {
        #expect(ColorTargetState.emptyState(ColorTargetState.noSequenceNotice).title == "No sequence open")
        #expect(ColorTargetState.emptyState(ColorTargetState.emptyNotice).title == "No video clips")
        let nothing = ColorTargetState.emptyState(ColorTargetState.nothingNotice)
        #expect(nothing.title == "No clip selected" && nothing.hint == "Select a clip in the timeline to grade it.")
        #expect(ColorTargetState.emptyState(ColorTargetState.multiNotice(3)).title == "Several clips selected")
        #expect(ColorClipsPanelView.emptyState(hasSequence: false, itemCount: 0)?.title == "No sequence open")
        #expect(ColorClipsPanelView.emptyState(hasSequence: true, itemCount: 0)?.title == "No video clips")
        #expect(ColorClipsPanelView.emptyState(hasSequence: true, itemCount: 2) == nil)
        #expect(ScopesPanelView.emptyState(scopesAvailable: true, hasSequence: true) == nil)
        #expect(ScopesPanelView.emptyState(scopesAvailable: true, hasSequence: false)?.title == "No picture to measure")
    }

    @Test func panelShowsEmptyStateWithoutTarget() throws {
        let (session, panel, _) = try rig()
        #expect(panel.emptyState.isHidden)
        session.select(clips: [])
        panel.pickWholeSequence()
        #expect(panel.emptyState.isHidden)
    }

    @Test func escWithdrawsTheWholeDrag() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        let before = current(session, clip.id)
        let depth = session.undoDepth
        model.onGestureBegan?()
        model.set(1, .exposure, 1)
        model.set(1, .exposure, 2)
        model.onGestureCancelled?()
        #expect(session.undoDepth == depth && !session.canUndo)
        #expect(current(session, clip.id).effects == before.effects)
        #expect(model.value(1, .exposure) == 0)
        // The next drag is its own step again.
        model.gesture { model.set(1, .exposure, 1) }
        #expect(session.undoDepth == depth + 1)
    }

    @Test func navigationUsesThePlayheadAndSkipsKeysPastTheClip() throws {
        let (session, panel, clip) = try rig()
        let model = try #require(panel.colorModels[clip.id])
        model.keyframe(.toggleAnimation, 1, .param(.exposure))               // key at 0
        // A key past the clip end (left by a trim) is no stop.
        let k = [ColorParam.exposure.parameterKey]
        var c = current(session, clip.id)
        let added = c.toggleColorKey(effect: 1, keys: k, atLocal: Time(5, 1))
        #expect(added)
        let tl = try #require(session.activeTimelineID)
        try session.perform("Test") { p in try p.edit(tl) { t in try t.replaceClip(c) } }
        let last = Time(59, 30)                                               // the clip's last frame
        session.seek(to: last)
        panel.sync([.project, .playhead])
        let st = model.keyframeState(1, .param(.exposure))
        #expect(st == KeyframeControlState.resolve(animated: true, onKey: false, hasPrevious: true, hasNext: false,
                                                    playheadInRange: true))
        model.keyframe(.next, 1, .param(.exposure))
        #expect(session.playhead == last)
        model.keyframe(.previous, 1, .param(.exposure))
        #expect(session.playhead == .zero)
    }
}
