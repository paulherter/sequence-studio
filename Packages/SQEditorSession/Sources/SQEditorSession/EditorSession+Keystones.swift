import Foundation
import SQCore

/// G1 Keystones: apply a keystone to a clip as ordinary keys, stretch it by its edges, save one from a clip. One undo
/// step each.
extension EditorSession {
    /// Applies `keystone` to `clip` at `span` (the timeline drop ghost); nil span = placed around the playhead (Effect
    /// Controls drop). Returns where it landed, nil (with `lastError`) when refused.
    @discardableResult
    public func applyKeystone(_ keystone: Keystone, to clip: Clip.ID, span: KeystoneSpan?) -> KeystoneSpan? {
        guard let tl = activeTimeline, let c = tl.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clip }) else {
            setError(Self.message(for: EditError.clipNotFound)); return nil
        }
        let place = span ?? keystone.placement(dropAt: playhead - c.start, clipDuration: c.duration)
        var landed: KeystoneSpan?
        guard attempt("Apply Keystone “\(keystone.name)”", { tl in
            landed = try tl.applyKeystone(keystone, to: clip, at: place.start, duration: place.duration)
        }) else { return nil }
        return landed
    }

    /// Edge drag on an applied keystone (one undo step). False (with `lastError`) when refused or nothing changed.
    @discardableResult
    public func restretchKeystone(on clip: Clip.ID, _ span: KeystoneSpan, to new: KeystoneSpan) -> Bool {
        guard new != span else { return false }
        return attempt("Change Keystone Length") { try $0.restretchKeystone(on: clip, span, to: new) }
    }

    /// A keystone from the keyed Position/Scale/Rotation/Opacity of the one selected video clip (`properties` nil = all
    /// keyed ones); nil when it has fewer than two key times there.
    public func keystoneFromSelectedClip(properties: Set<Keystone.Property>? = nil, name: String) -> Keystone? {
        guard let tl = activeTimeline, let c = singleSelectedClip, c.kind == .video else { return nil }
        let props = properties ?? Set(Keystone.Property.allCases)
        return Keystone.capture(from: c, properties: props,
                                frameSize: Vec2(Double(tl.format.displayWidth), Double(tl.format.height)), name: name)
    }
}
