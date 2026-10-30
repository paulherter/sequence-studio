import Foundation
import SQUIKit
import SQCore
import SQLibrary

/// Effect presets (Motion/Opacity + effects with keys and easing): save from a clip, apply to clips. One undo step each.
extension EditorSession {
    /// A Library preset item for `preset` (kind `.effect`, current payload version).
    public static func effectPresetItem(name: String, preset: EffectPreset) throws -> PresetItem {
        PresetItem(kind: .effect, name: name, payload: try preset.payload(), payloadVersion: EffectPreset.payloadVersion)
    }

    /// Preset from the one selected video clip (its linked audio may be selected too); nil when there is none or it
    /// has nothing to save.
    public func presetFromSelectedClip(anchor: EffectPreset.Anchor) -> EffectPreset? {
        guard let c = singleSelectedClip, c.kind == .video else { return nil }
        // C7: remember the sequence frame, so applying it to another size scales Position and points.
        let size = activeTimeline.map { Vec2(Double($0.format.displayWidth), Double($0.format.height)) }
        let p = EffectPreset.capture(from: c, anchor: anchor, frameSize: size)
        return p.isEmpty ? nil : p
    }

    /// Applies an `.effect` preset to `ids` (nil = the selected clips, else the clips under the playhead).
    /// False (with a fresh `lastError`) for another kind, an unreadable payload, no video clip or a refused edit.
    /// An apply that changes nothing is not a failure: true, no message.
    @discardableResult
    public func applyPreset(_ item: PresetItem, to ids: Set<Clip.ID>? = nil,
                            mode: EffectPreset.ApplyMode = .absolute) -> Bool {
        if item.kind == .transition { return applyTransitionPreset(item, edges: nil) }
        guard item.kind == .effect else { setError("“\(item.name)” is not an effect preset."); return false }
        let preset: EffectPreset
        do { preset = try EffectPreset(payload: item.payload, version: item.payloadVersion) } catch {
            setError("“\(item.name)” was made by a newer version of Sequence Studio or is damaged.")
            return false
        }
        // An audio-only preset (an imported voice chain) goes onto audio clips.
        let kind = preset.trackKind
        let targets = ids ?? Set(commandClips(kind: kind).map(\.id))
        guard !targets.isEmpty else { setError(SQL10n.format(kind == .audio ? "Select an audio clip to apply “%@”." : "Select a video clip to apply “%@”.", item.name)); return false }
        do { try performTimeline("Apply Preset “\(item.name)”") { try $0.applyPreset(preset, to: targets, mode: mode) } } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }

    // MARK: Built-in effect-stack presets (motion, keying, film looks, Voice: consolidation step 8)

    /// Effects panel row id prefix of the motion and keying presets (Presets folder, apply by double-click).
    public static let builtInPresetPrefix = EffectStackPresets.rowPrefix

    /// The one apply path of every built-in stack preset (`EffectStackPresets`; `id` is its id or its panel row id) onto
    /// `ids` (nil = the selected clips, else the clips under the playhead). The preset's effects are appended to each clip
    /// with fresh ids, Motion stays. An audio chain goes onto the audio clips among the targets and the linked audio of
    /// target video clips. One undo step, "Apply Preset “name”", like a Library preset.
    @discardableResult
    public func applyStackPreset(_ id: String, to ids: Set<Clip.ID>? = nil) -> Bool {
        guard let p = EffectStackPresets.preset(id: id) ?? EffectStackPresets.preset(rowID: id) else { setError("Unknown preset."); return false }
        let audio = p.trackKind == .audio
        let picked = ids ?? Set(commandClips(kind: audio ? nil : .video).map(\.id))
        let targets = audio ? audioEffectTargets(for: picked) : picked
        guard !targets.isEmpty else { setError(SQL10n.format(audio ? "Select an audio clip to apply “%@”." : "Select a video clip to apply “%@”.", p.name)); return false }
        do { try performTimeline("Apply Preset “\(p.name)”") { try $0.applyPreset(p.preset, to: targets) } } catch {
            setError(Self.message(for: error)); return false
        }
        return true
    }

    // MARK: Convert to Keyframes / Re-open as Effect (W7.5)

    func bakeClip(_ id: Clip.ID) -> Clip? { activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id } }

    /// Whether Convert to Keyframes is offered for `effect` of clip `clip` in the active timeline.
    public func canConvertToKeyframes(effect: ClipEffect.ID, in clip: Clip.ID) -> Bool {
        activeTimeline?.canConvertToKeyframes(effect: effect, in: clip) ?? false
    }

    /// Whether the newest baked record of `clip` can be re-opened (nil when the clip has none).
    public func canReopenAsEffect(in clip: Clip.ID) -> Bool {
        guard let c = bakeClip(clip), let last = c.bakedEffects.last else { return false }
        return c.canReopenAsEffect(last.id)
    }

    /// Bakes `effect` into Motion keys: one undo step. False (with `lastError`) when refused.
    @discardableResult
    public func convertToKeyframes(effect: ClipEffect.ID, in clip: Clip.ID) -> Bool {
        attempt("Convert to Keyframes") { try $0.convertToKeyframes(effect: effect, in: clip) }
    }

    /// Puts the newest baked effect of `clip` back: one undo step. False (with `lastError`) when refused.
    @discardableResult
    public func reopenAsEffect(in clip: Clip.ID) -> Bool {
        guard let record = bakeClip(clip)?.bakedEffects.last?.id else {
            setError(Self.message(for: BakeError.recordNotFound)); return false
        }
        return attempt("Re-open as Effect") { try $0.reopenAsEffect(record, in: clip) }
    }
}

/// The remembered absolute/relative choice for applying a preset (Library double-click, Option+Space).
public enum PresetApplyModeSetting {
    public static let key = "sq.presets.applyMode"
    public static func load(from d: UserDefaults = .standard) -> EffectPreset.ApplyMode {
        d.string(forKey: key).flatMap(EffectPreset.ApplyMode.init(rawValue:)) ?? .absolute
    }
    public static func save(_ m: EffectPreset.ApplyMode, to d: UserDefaults = .standard) { d.set(m.rawValue, forKey: key) }
}
