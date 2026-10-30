import Foundation
import SQCore

/// W5.1: format variants in the session. The Program monitor shows the active sequence in its active variant (or its
/// own format); Effect Controls and the transform overlay show and edit the selected clip as that variant shows it, and
/// `replaceDisplayedClip` stores Motion changes in the variant's override (`Timeline.applyDisplayedEdit`).
extension EditorSession {
    /// The variant the Program monitor shows for the active sequence; nil = its own format.
    public var activeVariantID: FormatVariant.ID? {
        guard let t = activeTimeline, let v = activeVariants[t.id], t.variant(v) != nil else { return nil }
        return v
    }

    public var activeVariant: FormatVariant? { activeTimeline?.variant(activeVariantID) }

    /// The canvas the Program monitor shows (the active variant's, else the sequence's).
    public var displayFormat: SequenceFormat? { activeTimeline.map { $0.format(for: activeVariantID) } }

    /// The active sequence as the monitor shows it: materialised in the active variant (clips resolved, the variant's
    /// format), or the sequence itself. For hit testing and the overlay; clip ids are the stored ones. Cheap: the view
    /// the engine was given (built once per change), so per-tick callers do not materialise the sequence again.
    public var displayTimeline: Timeline? {
        guard let id = activeTimelineID else { return nil }
        guard activeVariantID != nil else { return activeTimeline }
        if let p = pushedTimeline, p.id == id { return p }
        return project.variantView(of: id, variant: activeVariantID)?.timeline
    }

    /// `clip` (of the active sequence) as the active variant shows it, exactly as render resolves it (a nested clip
    /// whose inner sequence has the variant is not conformed: `Project.displayedClip`).
    public func displayedClip(_ clip: Clip) -> Clip {
        guard let t = activeTimeline else { return clip }
        return project.displayedClip(clip, in: t, variant: activeVariantID)
    }

    /// The clip Effect Controls shows: `singleSelectedClip` as the active variant shows it.
    public var displayedSelectedClip: Clip? { singleSelectedClip.map(displayedClip) }

    /// Effect Controls / overlay edit of a clip as displayed (`displayedClip` plus the change). With a variant active
    /// Motion changes go to its override; without one this is `replaceClip`. Gesture coalescing as `replaceClip`.
    public func replaceDisplayedClip(_ clip: Clip, name: String, continuesGesture: Bool) {
        guard let v = activeVariantID else { replaceClip(clip, name: name, continuesGesture: continuesGesture); return }
        if !continuesGesture { gestureCounter += 1 }
        let conforms = project.conformsPicture(of: clip, in: v)
        attempt(name, coalescing: "clip:\(clip.id):\(gestureCounter)") {
            try $0.applyDisplayedEdit(clip, variant: v, conformsPicture: conforms)
        }
    }

    /// Program monitor switcher: shows `variant` of the active sequence (nil = its own format). View state, no undo step.
    public func setActiveVariant(_ variant: FormatVariant.ID?) {
        guard let t = activeTimeline else { return }
        let v = t.variant(variant)?.id
        guard v != activeVariantID else { return }
        activeVariants[t.id] = v
        markViewStateChanged()                 // saved with the project (`activeVariants`)
        pushTimeline(force: true)
        notify([.project, .selection])
    }

    /// Adds a variant to the active sequence ("Add Format", one undo step) and shows it. nil when refused.
    @discardableResult
    public func addVariant(name: String, width: Int, height: Int, conform: ConformMode = .fill) -> FormatVariant.ID? {
        var id: FormatVariant.ID?
        guard attempt("Add Format", { id = try $0.addVariant(name: name, width: width, height: height, conform: conform) }),
              let id else { return nil }
        setActiveVariant(id)
        return id
    }

    /// Removes a variant of the active sequence and every clip's override for it ("Remove Format", one undo step).
    public func removeVariant(_ id: FormatVariant.ID) {
        attempt("Remove Format") { try $0.removeVariant(id) }
    }

    /// True while a variant is active and `clip` has its own value for `property` in it ("Reset to Automatic" on Motion rows).
    public func hasVariantOverride(_ property: VariantProperty, clip: Clip.ID) -> Bool {
        guard let v = activeVariantID, let o = activeTimeline?.override(of: clip, in: v) else { return false }
        return o.has(property)
    }

    /// Back to the automatic conform for `property` (tilt clears both axes). One undo step; false when there is nothing
    /// to reset (no active variant or no override of the property).
    @discardableResult
    public func resetVariantOverride(_ property: VariantProperty, clip: Clip.ID) -> Bool {
        guard let v = activeVariantID, hasVariantOverride(property, clip: clip) else { return false }
        return attempt("Reset \(property.rawValue.capitalized) to Automatic") {
            try $0.resetOverride(property, clip: clip, variant: v)
        }
    }

    /// "Add Format" from one of `SequenceConform.aspectPresets`, named after it.
    @discardableResult
    public func addVariant(_ preset: SequenceConform.AspectPreset) -> FormatVariant.ID? {
        addVariant(name: preset.name, width: preset.width, height: preset.height)
    }
}
