import Foundation
import SQCore
import SQText

/// What the Intro / Outro popups of a text or graphic item offer, and when a side is Custom. One place for the Text
/// block (popups) and the Controls column (keyframe rows of a Custom side). The saved animations come from the
/// `store` the host hands in (the window's Library keystones): there is no shared one, two windows never cross.
/// Where the saved Intro / Outro animations come from: the window's Library keystones (`KeystonesPanelModel` on the
/// Mac). A protocol so the choices stay portable while the Keystones panel model lives in SQTimelineUI.
@MainActor
public protocol AnimationKeystoneSource: AnyObject {
    func offeredAnimations(_ side: AnimationSide) -> [Keystone]
    /// The Library takes new keystones (a Custom side can be saved).
    var canSave: Bool { get }
    /// Stores a keystone; false when it could not.
    func save(_ k: Keystone) async -> Bool
}

extension KeystonesPanelModel: AnimationKeystoneSource {}

@MainActor
public enum AnimationChoices {
    /// Popup entry that turns the side into a Custom animation (its keys are edited in Controls).
    public static let customID = "custom"
    /// Popup entry that saves the side's Custom animation under a name.
    public static let saveID = "save"
    /// Prefix of a saved animation's id (a keystone of the Library).
    public static let savedPrefix = "mine:"

    /// The keystones a side offers: the built-in ones that start with the clip (Intro) or end with it (Outro), then the
    /// user's saved ones.
    public static func saved(_ side: AnimationSide, in store: (any AnimationKeystoneSource)?) -> [Keystone] {
        store?.offeredAnimations(side) ?? []
    }

    public static func frameSize(_ format: SequenceFormat?) -> Vec2 {
        format.map { Vec2(Double($0.width), Double($0.height)) } ?? Vec2(1080, 1920)
    }

    /// The preset ids of a side: Off, the neutral ones, the rest, then the saved ones.
    public static func presetIDs(_ side: AnimationSide, library: CaptionPresetLibrary, store: (any AnimationKeystoneSource)?) -> [String] {
        let presets = builtInIDs(side, library: library)
        let taken = Set(presets.map { AnimationPresetName.title(for: $0).lowercased() })
        // A built-in keystone with the name of a preset is that preset (listed once); a saved one always has its own entry.
        return presets + saved(side, in: store).filter { !$0.isBuiltIn || !taken.contains($0.name.lowercased()) }
            .map { savedPrefix + $0.id.uuidString }
    }

    private static func builtInIDs(_ side: AnimationSide, library: CaptionPresetLibrary) -> [String] {
        let all = library.animationIDs.filter { id in
            let a = library.animation(for: id)
            return a != .none && a.anchor == (side == .intro ? .start : .end)
        }
        let neutral = (side == .intro ? CaptionStyleLooks.neutralIntroIDs : CaptionStyleLooks.neutralOutroIDs).filter(all.contains)
        return ["none"] + neutral + all.filter { !neutral.contains($0) }
    }

    /// The template behind a preset id; nil for an unknown one. "none" is the empty template.
    public static func template(for id: String, side: AnimationSide, library: CaptionPresetLibrary, frameSize: Vec2,
                                store: (any AnimationKeystoneSource)?) -> KeyframeTemplate? {
        if id.hasPrefix(savedPrefix) {
            return saved(side, in: store).first { savedPrefix + $0.id.uuidString == id }?.animationTemplate(frameSize: frameSize)
        }
        return library.hasAnimation(id) ? library.animation(for: id) : nil
    }

    /// A side is Custom once its keys carry ids of their own (`KeyframeTemplate.withFreshKeyIDs`): a fact of the side
    /// alone, whatever the Library holds and whatever the sequence format is.
    public static func isCustom(_ t: KeyframeTemplate?) -> Bool {
        guard let t, !t.tracks.isEmpty else { return false }
        return t.hasOwnKeyIDs
    }

    /// The preset a side plays; nil for a Custom side and for a preset nobody knows any more (a saved animation that
    /// was deleted from the Library: it keeps playing, the popup shows "Saved"). The text animator is not part of the
    /// preset (it is chosen on its own): an animator-only side is "none". A saved animation matches in every sequence
    /// format (`sameShape`: its Position is a fraction of the frame).
    public static func presetID(of t: KeyframeTemplate?, side: AnimationSide, library: CaptionPresetLibrary, frameSize: Vec2,
                                store: (any AnimationKeystoneSource)?, preferred: String? = nil) -> String? {
        guard var preset = t, !preset.tracks.isEmpty else { return "none" }
        if preset.hasOwnKeyIDs { return nil }
        preset.textAnimator = nil
        let builtIn = builtInIDs(side, library: library).first { $0 != "none" && library.animation(for: $0).sameCurves(as: preset) }
        // A keystone stores no loop flag: the side keeps its own (`TextInspectorModel.saveCustomAnimation`), so looping
        // is not part of what makes a side a saved animation.
        let templates: [(id: String, template: KeyframeTemplate)] = saved(side, in: store).compactMap { k in
            guard var s = k.animationTemplate(frameSize: frameSize) else { return nil }
            s.loops = preset.loops
            return (savedPrefix + k.id.uuidString, s)
        }
        let exact = templates.filter { $0.template.sameCurves(as: preset) }.map(\.id)
        let shaped = templates.filter { $0.template.sameShape(as: preset) }.map(\.id)
        // Several animations can hold the same curves (a saved copy of a built-in one, two saved ones that differ only
        // in how far they move after a format change): the one the user picked or saved last is the one shown.
        if let preferred, preferred == builtIn || exact.contains(preferred) || shaped.contains(preferred) { return preferred }
        if let found = builtIn ?? exact.first ?? shaped.first { return found }
        // A preset whose zone length was changed (`TextInspectorModel.setZoneLength`) is still that preset.
        guard preset.duration > .zero else { return nil }
        func lengthAdjusted(_ t: KeyframeTemplate) -> Bool { t.retimed(toDuration: preset.duration).sameCurves(as: preset) }
        return builtInIDs(side, library: library).first { $0 != "none" && lengthAdjusted(library.animation(for: $0)) }
            ?? templates.first { lengthAdjusted($0.template) }?.id
    }

    public static func title(for id: String, side: AnimationSide, store: (any AnimationKeystoneSource)?) -> String {
        switch id {
        case "none": return "Off"
        case customID: return "Custom"
        case saveID: return "Save Custom\u{2026}"
        default:
            if id.hasPrefix(savedPrefix) { return saved(side, in: store).first { savedPrefix + $0.id.uuidString == id }?.name ?? unknownTitle }
            return AnimationPresetName.title(for: id)
        }
    }

    /// What the popup shows for a preset that is not in the list (its saved animation was deleted).
    public static let unknownTitle = "Saved"
}

/// A text clip's animations as the Controls rows read them: decoded once per generator payload, the Custom sides'
/// tracks already in clip time. A lane draw and a value read ask per row and per frame; they copy nothing.
private struct AnimationRows {
    let ref: GeneratorRef
    let duration: Time
    let set: AnimationSet
    let custom: [AnimationSide]
    /// Per Custom side: Scale, Rotation, Opacity (`AnimationParam` order without Position).
    var scalars: [AnimationSide: [AnimationParam: AnimatedProperty<Double>]] = [:]
    var positions: [AnimationSide: AnimatedProperty<Vec2>] = [:]
}

extension EffectControlsModel {
    /// Recently read clips, least recently used first (the shown one and, in a multi-selection, its peers): a read per
    /// row and frame decodes none of them. `rowsCapacity` follows the live selection.
    private static var rowsMemo: [AnimationRows] = []
    private static var rowsCapacity = 16
    /// Payload decodes so far (tests count them over repeated reads).
    static var rowsDecodeCount = 0

    /// Room for `count` selected clips (at least 16, at most 256).
    static func sizeRowsMemo(forSelection count: Int) {
        rowsCapacity = min(max(16, count + 4), 256)
        if rowsMemo.count > rowsCapacity { rowsMemo.removeFirst(rowsMemo.count - rowsCapacity) }
    }

    private static func rows(of c: Clip?) -> AnimationRows? {
        guard let c, let ref = c.generator, ref.kind == GeneratorRef.text else { return nil }
        if let r = rowsMemo.last, r.duration == c.duration, r.ref == ref { return r }
        if let i = rowsMemo.indices.first(where: { rowsMemo[$0].duration == c.duration && rowsMemo[$0].ref == ref }) {
            rowsMemo.append(rowsMemo.remove(at: i))         // most recently used goes last
            return rowsMemo[rowsMemo.count - 1]
        }
        rowsDecodeCount += 1
        guard let (_, a) = try? TextGenerator.decode(ref) else { return nil }
        let set = a ?? AnimationSet(in: nil, out: nil)
        var r = AnimationRows(ref: ref, duration: c.duration, set: set,
                              custom: AnimationSide.allCases.filter { AnimationChoices.isCustom(set.template($0)) })
        for side in r.custom {
            var scalars: [AnimationParam: AnimatedProperty<Double>] = [:]
            for p in AnimationParam.allCases where p != .position { scalars[p] = set.scalar(p, side: side, clipDuration: c.duration) }
            r.scalars[side] = scalars
            r.positions[side] = set.position(side: side, clipDuration: c.duration)
        }
        if rowsMemo.count >= rowsCapacity { rowsMemo.removeFirst(rowsMemo.count - rowsCapacity + 1) }
        rowsMemo.append(r)
        return r
    }

    /// The animations of a text clip (an empty set when it has none); nil for every other clip.
    static func animations(of c: Clip?) -> AnimationSet? { rows(of: c)?.set }

    /// The Custom sides of a text clip: only they have rows (a preset is never edited through Controls).
    static func customSides(of c: Clip?) -> [AnimationSide] { rows(of: c)?.custom ?? [] }

    /// The keyframe sections of a text clip's Custom sides (none while a side is Off or plays a preset).
    func customAnimationSections(of c: Clip) -> [EffectSection] { Self.customSides(of: c).map { .animation($0) } }

    /// A scalar row of a Custom side in clip time; nil for Position, other properties, other clips and a side that is
    /// not Custom.
    static func animScalar(_ p: EffectProperty, in c: Clip?) -> AnimatedProperty<Double>? {
        guard case .anim(let side, let param) = p, param != .position else { return nil }
        return rows(of: c)?.scalars[side]?[param]
    }

    /// The Position row of a Custom side in clip time.
    static func animVector(_ p: EffectProperty, in c: Clip?) -> AnimatedProperty<Vec2>? {
        guard case .anim(let side, .position) = p else { return nil }
        return rows(of: c)?.positions[side]
    }

    /// Edits one Custom side. A side that is Off or plays a preset is left alone: its keys are not the user's.
    private static func withAnimations(_ c: inout Clip, side: AnimationSide, _ body: (inout AnimationSet, Time) -> Void) {
        guard let ref = c.generator, ref.kind == GeneratorRef.text, let (t, a) = try? TextGenerator.decode(ref) else { return }
        var set = a ?? AnimationSet(in: nil, out: nil)
        guard AnimationChoices.isCustom(set.template(side)) else { return }
        body(&set, c.duration)
        guard set != a, let next = try? TextGenerator.makeRef(template: t, animations: set) else { return }
        c.generator = next
    }

    private static func keyTime(_ local: Time, _ duration: Time) -> Time { min(max(local, .zero), duration) }

    /// Edits a scalar row. A row only exists through its keys: a value typed into a row without keys becomes a key at
    /// the playhead.
    static func withAnimScalar(_ c: inout Clip, _ p: EffectProperty, local: Time, _ body: (inout AnimatedProperty<Double>) -> Void) {
        guard case .anim(let side, let param) = p, param != .position else { return }
        withAnimations(&c, side: side) { set, duration in
            set.edit(param, side: side, clipDuration: duration) { v in
                body(&v)
                if v.track.isEmpty, v.value != param.rest { v.track.insert(Keyframe(time: keyTime(local, duration), value: v.value)) }
            }
        }
    }

    static func withAnimVector(_ c: inout Clip, _ p: EffectProperty, local: Time, _ body: (inout AnimatedProperty<Vec2>) -> Void) {
        guard case .anim(let side, .position) = p else { return }
        withAnimations(&c, side: side) { set, duration in
            set.editPosition(side: side, clipDuration: duration) { v in
                body(&v)
                if v.track.isEmpty, v.value != .zero { v.track.insert(Keyframe(time: keyTime(local, duration), value: v.value)) }
            }
        }
    }
}
