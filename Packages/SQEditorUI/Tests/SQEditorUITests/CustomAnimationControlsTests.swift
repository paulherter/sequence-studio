import Foundation
import SQCore
import SQLibrary
import SQText
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor private extension EffectControlsModel {
    /// What the Intro and Outro popups show for the shown clip.
    func selectedInAndOut(_ lib: CaptionPresetLibrary) -> [String?] {
        let set = (try? CustomAnimationControlsTests.animations(self)) ?? nil
        return AnimationSide.allCases.map {
            AnimationChoices.presetID(of: set?.template($0), side: $0, library: lib, frameSize: CustomAnimationControlsTests.frame, store: nil)
        }
    }
}

/// A text clip's Custom intro / outro in Controls: one section per Custom side, four keyframe rows each, edits stored
/// in the clip's text generator; a Custom side saved under a name is a keystone and comes back as a choice.
@MainActor @Suite(.serialized) struct CustomAnimationControlsTests {
    static let template = TextTemplate(name: "T", text: "Hi", style: TextStyle(fontName: "Helvetica", size: 80, color: .white))
    static let frame = Vec2(1080, 1920)

    func clip(_ set: AnimationSet?) throws -> Clip {
        let id = UUID()
        return Clip(id: id, name: "Text", media: id, kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)), start: Time(1, 1),
                    generator: try TextGenerator.makeRef(template: Self.template, animations: set))
    }

    func model(_ set: AnimationSet?) throws -> EffectControlsModel {
        let m = EffectControlsModel()
        m.onEdit = { c, _, _ in m.setClip(c) }
        m.setClip(try clip(set))
        return m
    }

    func animations(_ m: EffectControlsModel) throws -> AnimationSet? {
        try Self.animations(m)
    }

    static func animations(_ m: EffectControlsModel) throws -> AnimationSet? {
        try TextGenerator.decode(try #require(m.clip?.generator)).1
    }

    /// A window's keystones with a Library that takes what is saved at once.
    func store() -> KeystonesPanelModel {
        let p = KeystonesPanelModel()
        p.onSave = { [unowned p] k in if let item = try? KeystoneLibrary.presetItem(for: k) { p.presets.append(item) } }
        return p
    }

    func inspector(_ set: AnimationSet = AnimationSet(in: nil, out: nil), store: KeystonesPanelModel? = nil,
                   frame: Vec2 = CustomAnimationControlsTests.frame) -> (TextInspectorModel, () -> AnimationSet) {
        let m = TextInspectorModel(style: TextStyle(), animations: set, library: .builtIn, fontFamilies: { ["Helvetica"] })
        m.frameSize = frame
        m.keystones = store
        final class Box { var set: AnimationSet; init(_ s: AnimationSet) { set = s } }
        let box = Box(set)
        m.onChange = { _, a in box.set = a }
        return (m, { box.set })
    }

    @Test func offAndPresetsShowNoRows() throws {
        let fade = CaptionPresetLibrary.builtIn.animation(for: "fade")
        for set in [nil, AnimationSet(in: fade, out: nil), AnimationSet(in: nil, out: CaptionPresetLibrary.builtIn.animation(for: "fade-out"))] {
            let m = try model(set)
            #expect(!m.visibleSections.contains { if case .animation = $0 { return true } else { return false } })
        }
    }

    @Test func customShowsFourRowsPerSideAfterTransform() throws {
        let m = try model(AnimationSet(in: .customStart(.intro), out: nil))
        let sections = m.visibleSections
        let i = try #require(sections.firstIndex(of: .animation(.intro)))
        #expect(sections[i - 1] == .motion)
        #expect(!sections.contains(.animation(.outro)))
        #expect(EffectSection.animation(.intro).properties == AnimationParam.allCases.map { EffectProperty.anim(.intro, $0) })
        #expect(EffectSection.animation(.intro).title == "Intro Animation" && EffectSection.animation(.outro).title == "Outro Animation")
        #expect(EffectProperty.anim(.outro, .scale).title == "Scale")
        // Raw values round-trip (twirl state, key selection).
        for side in AnimationSide.allCases {
            #expect(EffectSection(rawValue: EffectSection.animation(side).rawValue) == .animation(side))
            for p in AnimationParam.allCases {
                #expect(EffectProperty(rawValue: EffectProperty.anim(side, p).rawValue) == .anim(side, p))
            }
        }
    }

    @Test func rowsReadAndWriteTheGenerator() throws {
        let m = try model(AnimationSet(in: .customStart(.intro), out: .customStart(.outro)))
        let opacity = EffectProperty.anim(.intro, .opacity), scale = EffectProperty.anim(.intro, .scale)
        // The fade Custom starts from: two Opacity keys, the other rows rest without keys.
        #expect(m.track(opacity)?.keyIDs.count == 2)
        #expect(EffectControlsModel.animScalar(scale, in: m.clip)?.track.isEmpty == true)
        m.playhead = Time(1, 1)                                   // clip start
        #expect(m.scalarValue(opacity) == 0)
        m.playhead = Time(1, 1) + AnimationSet.customLength
        #expect(m.scalarValue(opacity) == 1)

        // A value typed into a row without keys becomes a key at the playhead; the outro stays what it was.
        let outro = try #require(try animations(m)?.animationOut)
        m.playhead = Time(1, 1)
        #expect(m.setValue(scale, to: 0.5))
        let set = try #require(try animations(m))
        let keys = try #require(set.animationIn?.track(for: "scale")?.track.keys)
        #expect(keys.map(\.time) == [.zero] && keys.map(\.value) == [0.5])
        #expect(set.animationOut == outro)
        #expect(set.sample(clipTime: .zero, clipDuration: Time(3, 1)).scale == 0.5)

        // Position is one row over two tracks.
        #expect(m.setVector(.anim(.intro, .position), to: Vec2(0, 120)))
        let after = try #require(try animations(m)?.animationIn)
        #expect(after.track(for: "positionY")?.track.keys.map(\.value) == [120])
        #expect(after.track(for: "positionX")?.track.keys.map(\.value) == [0])
        #expect(m.visibleSections.contains(.animation(.intro)))
    }

    /// Animation (In/Out) tracks store a Hold Ahead as a Hold: the entry is not offered there (key menu, Temporal
    /// submenu, curve chip menu, Graph Editor button) and applying it changes nothing.
    @Test func animationRowsDoNotOfferHoldAhead() throws {
        let m = try model(AnimationSet(in: .customStart(.intro), out: .customStart(.outro)))
        let opacity = EffectProperty.anim(.intro, .opacity)
        let ids = try #require(m.track(opacity)?.keyIDs)
        m.setSelection(for: opacity, ids: [ids[0]])
        #expect(!m.selectionTakesHoldAhead)
        let items = EffectKeyframeLanesView(model: m).makeKeyItems(onKey: true)
        #expect(!items.map(\.title).contains("Hold Ahead") && items.map(\.title).contains("Hold"))
        let temporal = items.first { $0.title == "Temporal Interpolation" }?.submenu ?? []
        #expect(!temporal.map(\.title).contains("Hold Ahead"))
        #expect(!InlineSpeedGraphView(property: opacity, model: m).curveMenuItems().map(\.title).contains("Hold Ahead"))
        let before = m.clip
        m.applyInterpolation(.holdAhead)
        m.applyGraphEase(.holdAhead)
        m.applySpeedChip(.holdAhead, for: opacity)
        #expect(m.clip == before)
    }

    @Test func outroKeysSitAtTheClipEnd() throws {
        let m = try model(AnimationSet(in: nil, out: .customStart(.outro)))
        let c = try #require(m.clip)
        let times = try #require(EffectControlsModel.animScalar(.anim(.outro, .opacity), in: c)?.track.keys.map(\.time))
        #expect(times == [c.duration - AnimationSet.customLength, c.duration])
    }

    @Test func popupChoicesOffFirstThenNeutralThenCustom() {
        let (m, read) = inspector()
        #expect(m.inAnimationIDs.prefix(4) == ["none", "fade", "rise", "scale-in"])
        #expect(m.outAnimationIDs.prefix(4) == ["none", "fade-out", "slide-out", "scale-out"])
        #expect(m.selectedInID == "none" && m.selectedOutID == "none")
        #expect(AnimationChoices.title(for: "none", side: .intro, store: nil) == "Off")
        #expect(AnimationChoices.title(for: AnimationChoices.customID, side: .intro, store: nil) == "Custom")

        m.setAnimation("scale-in", side: .intro)
        #expect(m.selectedInID == "scale-in" && !m.isCustom(.intro))
        #expect(read().animationIn?.hasOwnKeyIDs == false)

        // Custom from a preset keeps its curves and makes them the user's own; from Off it starts as a fade.
        m.makeCustom(.intro)
        #expect(m.isCustom(.intro) && m.selectedInID == nil)
        #expect(read().animationIn?.sameCurves(as: CaptionPresetLibrary.builtIn.animation(for: "scale-in")) == true)
        m.makeCustom(.outro)
        #expect(m.isCustom(.outro))
        #expect(read().animationOut?.sameCurves(as: .customStart(.outro)) == true)

        m.setAnimation("none", side: .intro)
        #expect(read().animationIn == nil && m.selectedInID == "none")
    }

    @Test func neutralPresetsDoNotOvershoot() throws {
        let lib = CaptionPresetLibrary.builtIn
        for (ids, anchor) in [(CaptionStyleLooks.neutralIntroIDs, AnimationAnchor.start), (CaptionStyleLooks.neutralOutroIDs, .end)] {
            for id in ids {
                let t = lib.animation(for: id)
                #expect(!t.tracks.isEmpty && t.anchor == anchor && t.textAnimator == nil, "\(id)")
                let set = anchor == .start ? AnimationSet(in: t, out: nil) : AnimationSet(in: nil, out: t)
                let d = Time(2, 1)
                for n in 0...60 {
                    let s = set.sample(clipTime: Time(Int64(n), 30), clipDuration: d)
                    #expect(s.scale <= 1.0001 && s.opacity >= -0.0001 && s.opacity <= 1.0001, "\(id) frame \(n): \(s)")
                }
                #expect(set.sample(clipTime: Time(1, 1), clipDuration: d).isRest, "\(id) rests in the middle")
            }
        }
    }

    @Test func savedCustomIsAKeystoneAndAChoice() async throws {
        let panel = store()
        let (m, read) = inspector(store: panel)
        #expect(!(await m.saveCustomAnimation(.intro, named: "Nothing")))          // Off: nothing to save
        m.makeCustom(.intro)
        #expect(await m.saveCustomAnimation(.intro, named: "Soft In"))
        let saved = panel.savedAnimations(.intro)
        let k = try #require(saved.first)
        #expect(saved.count == 1 && k.name == "Soft In" && k.animationSide == .intro && k.opacity != nil)
        let id = AnimationChoices.savedPrefix + k.id.uuidString
        #expect(m.inAnimationIDs.contains(id) && !m.outAnimationIDs.contains(id))
        #expect(AnimationChoices.title(for: id, side: .intro, store: panel) == "Soft In")
        // The side that was saved plays the saved animation: its popup shows the name, not "Custom".
        #expect(m.selectedInID == id && !m.isCustom(.intro) && m.animationTitle(.intro) == "Soft In")

        // Another item picks it: the same curves, as a preset (not Custom) that shows its name.
        let (other, otherRead) = inspector(store: panel)
        other.setAnimation(id, side: .intro)
        #expect(other.selectedInID == id && !other.isCustom(.intro))
        #expect(otherRead().animationIn?.sameCurves(as: try #require(read().animationIn)) == true)
    }

    /// A keystone stores no loop flag: the side that was saved keeps its own, and still shows the saved name.
    @Test func savingALoopingCustomKeepsItLooping() async throws {
        let lib = CaptionPresetLibrary.builtIn
        let looping = lib.animationIDs.filter { lib.animation(for: $0).loops && lib.animation(for: $0).anchor == .start }
        #expect(!looping.isEmpty)
        for id in looping {
            let panel = store()
            let (m, read) = inspector(store: panel)
            m.setAnimation(id, side: .intro)
            #expect(read().animationIn?.loops == true, "\(id)")
            m.makeCustom(.intro)
            #expect(await m.saveCustomAnimation(.intro, named: "Mine"), "\(id)")
            #expect(read().animationIn?.loops == true, "\(id) plays once after the save")
            #expect(!m.isCustom(.intro) && m.animationTitle(.intro) == "Mine", "\(id): \(m.animationTitle(.intro))")
            // Picking the name it already shows does not replace it with the non-looping stored copy.
            m.setAnimation(try #require(m.selectedInID), side: .intro)
            #expect(read().animationIn?.loops == true && m.animationTitle(.intro) == "Mine", "\(id) after picking it again")
        }
        // A looping side that is no built-in one is found again by a model that never saw the save.
        var loop = KeyframeTemplate.customStart(.intro)
        loop.loops = true
        let panel = store()
        let (m, read) = inspector(AnimationSet(in: loop, out: nil), store: panel)
        #expect(await m.saveCustomAnimation(.intro, named: "Loop"))
        let (other, _) = inspector(read(), store: panel)
        #expect(read().animationIn?.loops == true && other.animationTitle(.intro) == "Loop" && !other.isCustom(.intro))
    }

    /// Several animations can hold the same curves: the one picked or saved last names the side.
    @Test func theLastPickedNameWinsAmongEqualCurves() async throws {
        let panel = store()
        let (m, _) = inspector(store: panel)
        m.setAnimation("scale-in", side: .intro)
        m.makeCustom(.intro)
        #expect(await m.saveCustomAnimation(.intro, named: "Copy"))            // an unedited copy of a built-in one
        let copy = try #require(m.selectedInID)
        #expect(copy.hasPrefix(AnimationChoices.savedPrefix) && m.animationTitle(.intro) == "Copy")
        m.setAnimation("scale-in", side: .intro)
        #expect(m.selectedInID == "scale-in")
        m.setAnimation(copy, side: .intro)
        #expect(m.selectedInID == copy)

        // Two saved animations that differ only in how far they move, read in another format than they were set in.
        func rise(_ px: Double) -> KeyframeTemplate {
            KeyframeTemplate(tracks: [AnimationTrack(property: "positionY", keys: [(.zero, px, .linear), (Time(1, 2), 0, .linear)])],
                             duration: Time(1, 2), anchor: .start).withFreshKeyIDs()
        }
        var ids: [String] = []
        for (name, px) in [("Near", 96.0), ("Far", 192.0)] {
            let (s, _) = inspector(AnimationSet(in: rise(px), out: nil), store: panel)
            #expect(await s.saveCustomAnimation(.intro, named: name))
            ids.append(try #require(s.selectedInID))
        }
        let (wide, read) = inspector(store: panel, frame: Vec2(2160, 3840))
        for (id, name) in zip(ids, ["Near", "Far"]) {
            wide.setAnimation(id, side: .intro)
            #expect(wide.animationTitle(.intro) == name)
            // The same item after the sequence went back to the first format: "Near" there is as far as "Far" here.
            let (back, _) = inspector(read(), store: panel)
            back.setAnimation(id, side: .intro)
            #expect(back.animationTitle(.intro) == name)
        }
    }

    /// Review 1: a key of the clip that is moved or pasted rewrites every keyed row of the clip. A preset side has no
    /// rows, so it stays the preset bit for bit (it used to get new key ids, and Rise a second Position track).
    @Test func aPresetSideSurvivesEditsOfOtherKeys() throws {
        let lib = CaptionPresetLibrary.builtIn
        for (inID, outID) in [("fade", "fade-out"), ("rise", "slide-out")] {
            let original = AnimationSet(in: lib.animation(for: inID), out: lib.animation(for: outID))
            var c = try clip(original)
            c.animation.position.track = KeyframeTrack(keys: [Keyframe(time: Time(1, 2), value: Vec2(10, 0)),
                                                              Keyframe(time: Time(1, 1), value: Vec2(50, 0))])
            let m = EffectControlsModel()
            m.onEdit = { c, _, _ in m.setClip(c) }
            m.setClip(c)
            #expect(!EffectControlsModel.allProperties(in: c).contains { if case .anim = $0 { return true } else { return false } }, "\(inID)")
            #expect(Set(EffectControlsModel.tracks(of: c).keys) == [EffectProperty.position.id], "\(inID)")

            // Drag the second Position key.
            m.playhead = Time(1, 1)
            m.select([.init(property: EffectProperty.position.id, keyID: c.animation.position.track.keys[1].id)], extend: false)
            #expect(m.moveSelection(by: Time(1, 2)) == Time(1, 2))
            #expect(m.clip?.animation.position.track.keys.map(\.time) == [Time(1, 2), Time(3, 2)])
            #expect(try animations(m) == original, "\(inID) after a key drag")
            #expect(m.selectedInAndOut(lib) == [inID, outID], "\(inID) after a key drag")

            // Copy it and paste it later in the clip.
            #expect(m.copyKeys())
            m.playhead = Time(1, 1) + Time(5, 2)
            #expect(m.pasteKeys())
            #expect(m.clip?.animation.position.track.keys.count == 3)
            #expect(try animations(m) == original, "\(inID) after a paste")

            // A preset has no rows: nothing writes into it.
            _ = m.setValue(.anim(.intro, .opacity), to: 0.5)
            _ = m.setVector(.anim(.outro, .position), to: Vec2(5, 5))
            #expect(try animations(m) == original, "\(inID) after a row write")
            #expect(m.selectedInAndOut(lib) == [inID, outID], "\(inID) at the end")
        }
    }

    @Test func noPresetIsCustom() {
        let lib = CaptionPresetLibrary.builtIn
        #expect(!lib.animationIDs.isEmpty)
        for id in lib.animationIDs {
            let t = lib.animation(for: id)
            #expect(!t.hasOwnKeyIDs && !AnimationChoices.isCustom(t), "\(id)")
            // The ids its rows would show are not "own" either: writing them back could never make it Custom.
            let set = AnimationSet(in: t, out: t)
            for side in AnimationSide.allCases {
                let keys = t.tracks.flatMap { set.track($0.property, side: side, clipDuration: Time(3, 1)).track.keys }
                let shown = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", track: KeyframeTrack(keys: keys.enumerated().map { n, k in
                    var k = k; k.time = Time(Int64(n), 30); return k
                }))], duration: Time(1, 1))
                #expect(!shown.hasOwnKeyIDs, "\(id)")
            }
        }
    }

    /// Review 2: a saved animation stores Position as a fraction of the frame. The side keeps its name in another
    /// sequence format; once the Library loses the animation the side still plays, says "Saved" and is not Custom.
    @Test func aSavedAnimationKeepsItsNameInEveryFormat() async throws {
        var s = AnimationSet(in: .customStart(.intro), out: nil)
        s.editPosition(side: .intro, clipDuration: Time(3, 1)) { p in
            p.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(-200, 300)), Keyframe(time: AnimationSet.customLength, value: .zero)])
        }
        let panel = store()
        let (m, read) = inspector(s, store: panel)
        #expect(m.isCustom(.intro) && m.canSaveAnimations)
        #expect(await m.saveCustomAnimation(.intro, named: "Fly In"))
        let k = try #require(panel.savedAnimations(.intro).first)
        let id = AnimationChoices.savedPrefix + k.id.uuidString
        #expect(m.selectedInID == id)

        // The same item in a 4K landscape sequence (format changed, or pasted there).
        let (wide, _) = inspector(read(), store: panel, frame: Vec2(3840, 2160))
        #expect(wide.selectedInID == id && !wide.isCustom(.intro) && wide.animationTitle(.intro) == "Fly In")
        // Picked there it has other pixels, and reads the same back in the portrait sequence.
        wide.setAnimation("none", side: .intro)
        wide.setAnimation(id, side: .intro)
        #expect(wide.animations.animationIn != read().animationIn)
        let (tall, _) = inspector(wide.animations, store: panel)
        #expect(tall.selectedInID == id)

        // Deleted from the Library: the side keeps playing, without a name, and is not editable until "Custom".
        panel.presets = []
        #expect(panel.savedAnimations(.intro).isEmpty)
        #expect(m.selectedInID == nil && !m.isCustom(.intro) && m.animationTitle(.intro) == "Saved")
        #expect(!m.inAnimationIDs.contains(id))
        let before = try #require(read().animationIn)
        m.makeCustom(.intro)
        #expect(m.isCustom(.intro) && read().animationIn?.sameCurves(as: before) == true)
    }

    /// Review 5: each window has its own Library keystones; a model without one offers and saves nothing.
    @Test func savedAnimationsDoNotCrossWindows() async throws {
        let a = store(), b = store()
        let (first, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil), store: a)
        let (second, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil), store: b)
        let (alone, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil))
        #expect(await first.saveCustomAnimation(.intro, named: "Mine"))
        #expect(a.savedAnimations(.intro).count == 1 && b.savedAnimations(.intro).isEmpty)
        #expect(first.inAnimationIDs.count == second.inAnimationIDs.count + 1)
        #expect(second.isCustom(.intro) && second.savedAnimations.allSatisfy(\.isBuiltIn))
        let aloneSaved = await alone.saveCustomAnimation(.intro, named: "Mine")
        #expect(!alone.canSaveAnimations && !aloneSaved && alone.isCustom(.intro))
        // Whichever model was made last, a Custom side reads as Custom and a preset as its preset.
        _ = KeystonesPanelModel()
        #expect(first.selectedInID == AnimationChoices.savedPrefix + (try #require(a.savedAnimations(.intro).first)).id.uuidString)
    }

    /// Review 6: a save that did not happen is said; after one that did the popup shows the saved name.
    @Test func aFailedSaveIsSaidAndASavedSideShowsItsName() async {
        let (m, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil))
        let block = TextBlockView(model: m, context: .clip)
        var notices: [String] = []
        block.askLookName = { _, _ in "Mine" }
        block.onNotice = { notices.append($0) }
        await block.saveAnimation(.intro)             // no Library attached
        #expect(notices.count == 1 && m.isCustom(.intro))
        let panel = store()                 // the model holds it weakly
        m.keystones = panel
        await block.saveAnimation(.intro)
        #expect(panel.savedAnimations(.intro).map(\.name) == ["Mine"])
        #expect(notices.count == 1 && !m.isCustom(.intro) && m.animationTitle(.intro) == "Mine")
    }

    /// The Library stores asynchronously: until it answers the side stays Custom and the popup does not say "Saved";
    /// a refusal leaves the side Custom, an edit made meanwhile is kept.
    @Test func theSideFollowsTheStoresResultNotTheRequest() async throws {
        let panel = KeystonesPanelModel()
        var release: CheckedContinuation<Bool, Never>?
        panel.onSaveStored = { [unowned panel] k in
            await withCheckedContinuation { release = $0 }
            if let item = try? KeystoneLibrary.presetItem(for: k) { panel.presets.append(item) }
            return true
        }
        let (m, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil), store: panel)
        let task = Task { await m.saveCustomAnimation(.intro, named: "Slow") }
        while release == nil { await Task.yield() }
        #expect(m.isCustom(.intro) && m.animationTitle(.intro) == "Custom" && panel.savedAnimations(.intro).isEmpty)
        release?.resume(returning: true)
        #expect(await task.value)
        #expect(!m.isCustom(.intro) && m.animationTitle(.intro) == "Slow")

        // The Library refuses: nothing is stored, the side stays Custom.
        let refusing = KeystonesPanelModel()
        refusing.onSaveStored = { _ in false }
        let (r, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil), store: refusing)
        let refused = await r.saveCustomAnimation(.intro, named: "No")
        #expect(!refused && r.isCustom(.intro))
        // An answer of true for a keystone the Library does not list is no save either.
        let liar = KeystonesPanelModel()
        liar.onSaveStored = { _ in true }
        let (l, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil), store: liar)
        let liarSaved = await l.saveCustomAnimation(.intro, named: "Lie")
        #expect(!liarSaved && l.isCustom(.intro) && l.animationTitle(.intro) == "Custom")
    }

    /// A save started on one clip never lands on the clip selected meanwhile, however alike their animations are.
    @Test func aSaveAppliesOnlyToItsOwnTarget() async throws {
        let panel = KeystonesPanelModel()
        var release: CheckedContinuation<Bool, Never>?
        panel.onSaveStored = { [unowned panel] k in
            await withCheckedContinuation { release = $0 }
            if let item = try? KeystoneLibrary.presetItem(for: k) { panel.presets.append(item) }
            return true
        }
        let custom = AnimationSet(in: .customStart(.intro), out: nil)
        let (m, _) = inspector(custom, store: panel)
        m.target = "clip A"
        let task = Task { await m.saveCustomAnimation(.intro, named: "Slow") }
        while release == nil { await Task.yield() }
        m.target = "clip B"                          // a duplicate with the identical Custom Intro is selected
        m.load(style: m.style, animations: custom)
        release?.resume(returning: true)
        #expect(await task.value)
        #expect(panel.savedAnimations(.intro).count == 1)       // stored, but not applied to B
        #expect(m.isCustom(.intro) && m.animationTitle(.intro) == "Custom")
    }

    /// A second Save pick while the first save is pending starts nothing.
    @Test func aSecondSavePickWhilePendingIsIgnored() async throws {
        let panel = KeystonesPanelModel()
        var release: CheckedContinuation<Bool, Never>?
        panel.onSaveStored = { [unowned panel] k in
            await withCheckedContinuation { release = $0 }
            if let item = try? KeystoneLibrary.presetItem(for: k) { panel.presets.append(item) }
            return true
        }
        let (m, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil), store: panel)
        let block = TextBlockView(model: m, context: .clip)
        var asked = 0
        block.askLookName = { _, _ in asked += 1; return "Once" }
        block.pickAnimation(AnimationChoices.saveID, side: .intro)
        block.pickAnimation(AnimationChoices.saveID, side: .intro)
        while release == nil { await Task.yield() }
        block.pickAnimation(AnimationChoices.saveID, side: .intro)      // still pending
        release?.resume(returning: true)
        while m.isCustom(.intro) { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(asked == 1 && panel.savedAnimations(.intro).count == 1)
        // Finished: a new save is possible again.
        let second = store()                            // the model holds it weakly
        let (n, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil), store: second)
        let other = TextBlockView(model: n, context: .clip)
        other.askLookName = { _, _ in asked += 1; return "Again" }
        other.pickAnimation(AnimationChoices.saveID, side: .intro)
        while n.isCustom(.intro) { await Task.yield() }
        #expect(asked == 2)
    }

    /// 40 selected text clips: after the first pass no read decodes again.
    @Test func aLargeSelectionDecodesEachClipOnce() throws {
        func fade() throws -> Clip {
            let d = AnimationSet.customLength
            let t = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (d, 1, .linear)])],
                                     duration: d, anchor: .start).withFreshKeyIDs()
            return try clip(AnimationSet(in: t, out: nil))
        }
        let clips = try (0..<40).map { _ in try fade() }
        let m = EffectControlsModel()
        m.setClip(clips[0], peers: Array(clips.dropFirst()))
        let p = EffectProperty.anim(.intro, .opacity)
        for c in clips { _ = EffectControlsModel.animScalar(p, in: c) }
        let after = EffectControlsModel.rowsDecodeCount
        for _ in 0..<3 { for c in clips { _ = EffectControlsModel.animScalar(p, in: c) } }
        #expect(EffectControlsModel.rowsDecodeCount == after)
    }

    /// A value typed into a keyless row keys every selected clip at its own local playhead.
    @Test func aTypedValueKeysEachPeerAtItsOwnTime() throws {
        let custom = AnimationSet(in: .customStart(.intro), out: nil)
        let a = try clip(custom)                      // starts at 1 s, 3 s long
        var b = try clip(custom)
        b.start = Time(3, 1)
        let m = EffectControlsModel()
        var steps: [[Clip]] = []
        m.onEditMany = { clips, _, _ in steps.append(clips) }
        m.setClip(a, peers: [b])
        m.playhead = Time(7, 2)                        // 2.5 s into A, 0.5 s into B
        #expect(m.setValue(.anim(.intro, .rotation), to: 30))
        let edited = try #require(steps.first)
        let keyTimes = edited.map { EffectControlsModel.animScalar(.anim(.intro, .rotation), in: $0)?.track.keys.map(\.time) }
        #expect(keyTimes == [[Time(5, 2)], [Time(1, 2)]])
    }

    /// Built-in keystones of the side are offered first, each once, then the saved ones.
    @Test func builtInKeystonesArePresetsBeforeTheSavedOnes() async throws {
        let panel = store()
        let (m, _) = inspector(AnimationSet(in: .customStart(.intro), out: nil), store: panel)
        let builtIns = Keystone.builtIns.filter { $0.animationSide == .intro }
        #expect(!builtIns.isEmpty)
        #expect(await m.saveCustomAnimation(.intro, named: "Mine"))
        let ids = m.inAnimationIDs
        let mine = AnimationChoices.savedPrefix + (try #require(panel.savedAnimations(.intro).first)).id.uuidString
        // A built-in keystone named like a caption preset is that preset (listed once): the rest come before the saved one.
        let mineAt = try #require(ids.firstIndex(of: mine))
        let builtInIDs = ids[..<mineAt].filter { $0.hasPrefix(AnimationChoices.savedPrefix) }
        #expect(!builtInIDs.isEmpty && ids[(mineAt + 1)...].allSatisfy { !$0.hasPrefix(AnimationChoices.savedPrefix) })
        #expect(builtInIDs.allSatisfy { id in builtIns.contains { AnimationChoices.savedPrefix + $0.id.uuidString == id } })
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids.map { AnimationChoices.title(for: $0, side: .intro, store: panel) }).count == ids.count)
        #expect(!m.outAnimationIDs.contains(builtInIDs[0]))
        // Picking one plays its curves and names the side.
        let first = try #require(builtIns.first { AnimationChoices.savedPrefix + $0.id.uuidString == builtInIDs[0] })
        m.setAnimation(builtInIDs[0], side: .intro)
        #expect(m.animationTitle(.intro) == first.name && !m.isCustom(.intro))
    }

    /// A built-in keystone's own curve (`easing`) shapes the side when it is picked.
    @Test func aKeystonesEasingShapesThePickedSide() throws {
        let panel = store()
        var k = Keystone(name: "Eased", duration: Time(1, 2), anchor: .clipStart,
                         opacity: KeyframeTrack(keys: [Keyframe(time: .zero, value: 0.0), Keyframe(time: Time(1, 2), value: 1.0)]))
        k.easing = .fastStart
        panel.onSave?(k)
        let (m, read) = inspector(store: panel)
        m.setAnimation(AnimationChoices.savedPrefix + k.id.uuidString, side: .intro)
        let keys = try #require(read().animationIn?.track(for: "opacity")?.track.keys)
        #expect(keys.allSatisfy { $0.interpolation == .bezier } && keys[0].outHandle == EasingCurve.fastStart.outHandle)
        #expect(m.animationTitle(.intro) == "Eased")
    }

    /// Multi-selection: a Custom side shows its rows when every clip has it Custom; a row reads mixed where the clips
    /// differ, and one edit goes to all clips in one step.
    @Test func customRowsInAMultiSelection() throws {
        func fade(_ to: Double) -> AnimationSet {
            let d = AnimationSet.customLength
            let t = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 0, .linear), (d, to, .linear)])],
                                     duration: d, anchor: .start).withFreshKeyIDs()
            return AnimationSet(in: t, out: nil)
        }
        let a = try clip(fade(1)), b = try clip(fade(0.5)), preset = try clip(AnimationSet(in: CaptionPresetLibrary.builtIn.animation(for: "fade"), out: nil))
        let m = EffectControlsModel()
        var steps: [[Clip]] = []
        m.onEditMany = { clips, _, _ in steps.append(clips); m.setClip(clips[0], peers: Array(clips.dropFirst())) }
        m.setClip(a, peers: [b])
        #expect(m.visibleSections.contains(.animation(.intro)))
        let opacity = EffectProperty.anim(.intro, .opacity)
        m.playhead = Time(1, 1) + AnimationSet.customLength
        #expect(m.isMixed(opacity))
        #expect(!m.isMixed(.anim(.intro, .scale)))
        #expect(m.setValue(opacity, to: 0.25))
        #expect(steps.count == 1)
        for c in steps[0] {
            let set = try #require(EffectControlsModel.animations(of: c))
            #expect(set.animationIn?.track(for: "opacity")?.track.keys.last?.value == 0.25)
        }
        // A clip whose Intro is a preset (or Off) has no keys to edit: the section hides.
        let mixedKinds = EffectControlsModel()
        mixedKinds.setClip(a, peers: [preset])
        #expect(!mixedKinds.visibleSections.contains(.animation(.intro)))
    }

    /// Review 7: keys set in Controls reach the Text block without ending an edit session that is open there.
    @Test func adoptingAnimationsKeepsAnOpenEditSession() {
        let (m, _) = inspector()
        var ended = 0
        m.onEndEditing = { ended += 1 }
        m.beginEditing()
        m.adopt(animations: AnimationSet(in: .customStart(.intro), out: nil))
        #expect(ended == 0 && m.isCustom(.intro))
        m.load(style: m.style, animations: m.animations)
        #expect(ended == 1)
    }

    /// A lane draw and a value read ask for a row's track every time: that must not copy keys or build strings.
    @Test func rowReadsAreCheap() throws {
        let m = try model(AnimationSet(in: .customStart(.intro), out: .customStart(.outro)))
        let c = try #require(m.clip)
        let props = AnimationSide.allCases.flatMap { EffectSection.animation($0).properties }
        let rounds = 2000
        var keys = 0
        let t0 = ContinuousClock.now
        for _ in 0..<rounds {
            for p in props {
                if case .anim(_, .position) = p { keys += EffectControlsModel.animVector(p, in: c)?.track.keys.count ?? 0 }
                else { keys += EffectControlsModel.animScalar(p, in: c)?.track.keys.count ?? 0 }
            }
        }
        let d = ContinuousClock.now - t0
        let nanos = Double(d.components.seconds) * 1e9 + Double(d.components.attoseconds) / 1e9
        let per = nanos / Double(rounds * props.count)
        #expect(keys == rounds * 4)
        try? String(format: "PERF custom animation row read: %.0f ns", per)
            .write(toFile: NSTemporaryDirectory() + "sq-anim-row-read.txt", atomically: true, encoding: .utf8)
        #expect(per < 5_000, "a row read took \(per) ns")
    }
}
