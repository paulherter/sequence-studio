import Foundation
import SQCore
import SQText

/// Where a Look lives: shipped with the app, in the user's Look store, or in the project (its style kit).
public enum LookScope: String, Sendable, Hashable { case builtIn, user, project }

/// One Look of the library, addressed by where it lives.
public struct LookRef: Hashable, Sendable {
    public var scope: LookScope
    public var id: String

    public init(scope: LookScope, id: String) { self.scope = scope; self.id = id }

    /// What an item stores as its applied Look (`TextTemplate.lookID`) and what caption refs carry (`look-<token>`).
    public var token: String { scope == .project ? StyleKit.lookID(id) : id }
}

public struct LookEntry: Identifiable, Hashable, Sendable {
    public var ref: LookRef
    public var look: Look
    public var id: String { ref.token }
}

/// What a Look is applied to and read from.
public enum LookTarget: Hashable, Sendable {
    case textClip(Clip.ID)
    /// The one selected text item (layer) of a graphic clip.
    case graphicText(Clip.ID, UUID)
    case captions
}

/// The one Look API of the session: list, apply, update from current, save as new, rename, delete, and the edited state.
/// It works on the single selected text clip, else on the captions of the active sequence. `store` is the user's Look
/// store (tests pass their own).
extension EditorSession {
    /// A built-in Look applied to captions is copied into the project under this id prefix, so the project draws the same
    /// on any machine and build. Such copies are not listed as project Looks.
    static let builtInLookPrefix = "builtin-"

    private static func isHiddenKitLook(_ id: String) -> Bool {
        id.hasPrefix(CaptionStyleEdit.ownLookPrefix) || id.hasPrefix(builtInLookPrefix)
    }

    /// Every Look: built-in, then the user's (creation order), then the project's (by name).
    public func looks(store: LookStore = .shared) -> [LookEntry] {
        let project = (project.styleKit?.projectLooks() ?? []).filter { !Self.isHiddenKitLook($0.id) }
        return LookLibrary.builtIns.map { LookEntry(ref: LookRef(scope: .builtIn, id: $0.id), look: $0) }
            + store.library.user.map { LookEntry(ref: LookRef(scope: .user, id: $0.id), look: $0) }
            + project.map { LookEntry(ref: LookRef(scope: .project, id: $0.id), look: $0) }
    }

    public func look(_ ref: LookRef, store: LookStore = .shared) -> Look? {
        switch ref.scope {
        case .builtIn: LookLibrary.builtIns.first { $0.id == ref.id }
        case .user: store.library.look(ref.id).flatMap { $0.isBuiltIn ? nil : $0 }
        case .project: project.styleKit?.look(ref.id)
        }
    }

    public var lookTarget: LookTarget? {
        if selection.count == 1, let id = selection.first {
            if let sel = graphicLayerSelection, sel.clip == id, sel.layers.count == 1, let layer = sel.layers.first,
               textContent(.graphicText(id, layer)) != nil { return .graphicText(id, layer) }
            if textContent(.textClip(id)) != nil { return .textClip(id) }
        }
        if let tl = activeTimeline, !tl.captionTracks.isEmpty { return .captions }
        return nil
    }

    /// Whether the target's style still equals the Look it was given (`LookState`).
    public func lookState(store: LookStore = .shared) -> LookState {
        guard let cur = currentLookValues(store: store), let ref = cur.applied, let look = look(ref, store: store) else { return .none }
        if !cur.carried { return .edited(ref.token) }
        return look.differs(fromStyle: cur.style, animation: cur.animation) ? .edited(ref.token) : .applied(ref.token)
    }

    /// The Look the target was given, if it still exists.
    public func appliedLook(store: LookStore = .shared) -> LookRef? { currentLookValues(store: store)?.applied }

    /// Gives the target the Look: one undo step. A Look without an animation leaves the target's animation as it is.
    @discardableResult
    public func applyLook(_ ref: LookRef, store: LookStore = .shared, captionTrack: CaptionTrack.ID? = nil) -> Bool {
        guard let target = lookTarget, let look = look(ref, store: store) else { return false }
        switch target {
        case .textClip, .graphicText:
            guard let (template, anims) = textContent(target) else { return false }
            let given = Self.givingLook(look, token: ref.token, to: template, animations: anims)
            let written = writeText(target, template: given.template, animations: given.animations)
            if written { rememberTextLook(ref) }
            return written
        case .captions:
            var kit = project.styleKit
            var token = ref.token
            if ref.scope == .builtIn {
                var copy = look
                copy.id = Self.builtInLookPrefix + look.id
                var k = kit ?? StyleKit()
                guard (try? k.setLook(copy)) != nil else { return false }
                (kit, token) = (k, StyleKit.lookID(copy.id))
            }
            return giveCaptionTracks(look: look, styleToken: token, rememberedToken: ref.token, kit: kit, track: captionTrack)
        }
    }

    /// Writes the Look's style, animation and karaoke onto one caption track (`track`) or all of them (nil); the
    /// captions of those tracks follow the track again. One undo step. `kit` is the project kit `styleToken` lives in.
    func giveCaptionTracks(look: Look, styleToken: String, rememberedToken: String, kit: StyleKit?, track: CaptionTrack.ID?) -> Bool {
        guard let tl = activeTimeline, let tlID = activeTimelineID else { return false }
        let styleRef = CaptionLook.styleID(for: styleToken)
        let animationRef = look.animation == nil ? nil : CaptionLook.animationID(for: styleToken)
        let tracks = tl.captionTracks.map(\.id).filter { track == nil || $0 == track }
        guard !tracks.isEmpty else { return false }
        let all = Set(tl.captionTracks.filter { tracks.contains($0.id) }.flatMap(\.items).map(\.id))
        do {
            try perform("Apply Look") { p in
                if kit != p.styleKit { p.styleKit = kit }
                try p.edit(tlID) { t in
                    for id in tracks {
                        try t.setCaptionStyle(styleRef: styleRef, animationRef: animationRef, track: id)
                        try t.setCaptionLook(rememberedToken, track: id)
                        if let k = look.karaoke { try t.setCaptionKaraoke(k, track: id) }
                    }
                    try t.setCaptionItemStyle(all, styleRef: nil)
                }
                CaptionStyleEdit.pruneOwnLooks(&p)
                CaptionStyleEdit.pruneKitLooks(&p, prefix: Self.builtInLookPrefix)
            }
            return true
        } catch {
            setError(Self.message(for: error))
            return false
        }
    }

    /// Overwrites the Look with the target's current style ("Update Look"); the target then counts as carrying it.
    /// The animation is taken too when the Look has one or the target is the captions. Built-in Looks cannot change.
    /// One undo step (a Look of the user's store is not part of undo; giving it to the target is).
    @discardableResult
    public func updateLook(_ ref: LookRef, store: LookStore = .shared) throws -> Bool {
        guard let target = lookTarget, var look = look(ref, store: store),
              let cur = currentLookValues(store: store, slotOf: look) else { return false }
        let depth = undoDepth
        let takesAnimation = look.animation != nil || target == .captions
        look.style = cur.style
        if takesAnimation { look.animation = cur.animation }
        switch ref.scope {
        case .builtIn: return false
        case .user:
            let style = look.style, animation = look.animation
            guard try store.edit({ $0.update(ref.id) { ($0.style, $0.animation) = (style, animation) } }) else { return false }
        case .project:
            var kit = project.styleKit ?? StyleKit()
            try kit.setLook(look)
            setStyleKit(kit, name: "Update Look")
        }
        if cur.applied != ref || !cur.carried { applyLook(ref, store: store) }
        if undoDepth > depth + 1 { foldUndo(fromDepth: depth, name: "Update Look") }
        return true
    }

    /// Saves the target's current style as a new Look and gives it to the target: one undo step. Nil for an empty name.
    @discardableResult
    public func saveLookAsNew(name: String, scope: LookScope = .user, store: LookStore = .shared) throws -> LookRef? {
        guard let target = lookTarget, let cur = currentLookValues(store: store) else { return nil }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        // A text clip that does not animate saves a Look without an animation (it then fits any animation).
        let animation = target == .captions || cur.animation != KeyframeTemplate.none ? cur.animation : nil
        let depth = undoDepth
        let ref: LookRef
        switch scope {
        case .builtIn: return nil
        case .user:
            guard let id = try store.edit({ $0.add(name: n, style: cur.style, animation: animation, karaoke: cur.karaoke) }) else { return nil }
            ref = LookRef(scope: .user, id: id)
        case .project:
            var kit = project.styleKit ?? StyleKit()
            let id = UUID().uuidString
            try kit.setLook(Look(id: id, name: n, style: cur.style, animation: animation, karaoke: cur.karaoke))
            setStyleKit(kit, name: "Save Look")
            ref = LookRef(scope: .project, id: id)
        }
        applyLook(ref, store: store)
        if undoDepth > depth + 1 { foldUndo(fromDepth: depth, name: "Save Look") }
        return ref
    }

    @discardableResult
    public func renameLook(_ ref: LookRef, to name: String, store: LookStore = .shared) throws -> Bool {
        switch ref.scope {
        case .builtIn: return false
        case .user: return try store.edit { $0.rename(ref.id, to: name) }
        case .project:
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, var kit = project.styleKit, kit.looks[ref.id] != nil else { return false }
            kit.looks[ref.id]?.name = n
            setStyleKit(kit, name: "Rename Look")
            return true
        }
    }

    /// Deletes a Look. A project Look that captions still carry (as their style or only as their animation) is kept
    /// (false): they would lose it.
    @discardableResult
    public func deleteLook(_ ref: LookRef, store: LookStore = .shared) throws -> Bool {
        switch ref.scope {
        case .builtIn: return false
        case .user: return try store.edit { $0.delete(ref.id) }
        case .project:
            guard var kit = project.styleKit, kit.looks[ref.id] != nil else { return false }
            guard !CaptionStyleEdit.isKitLookUsed(ref.id, refs: CaptionStyleEdit.captionRefs(in: project)) else { return false }
            kit.looks[ref.id] = nil
            setStyleKit(kit, name: "Delete Look")
            return true
        }
    }

    // MARK: Private

    /// Stores the template on the target as one undo step.
    func writeText(_ target: LookTarget, template: TextTemplate, animations: AnimationSet?) -> Bool {
        switch target {
        case .textClip(let id):
            updateTextClip(id, template: template, animations: animations, continuesGesture: false)
            return true
        case .graphicText(let clipID, let layerID):
            guard let ref = try? TextGenerator.makeRef(template: template, animations: animations) else { return false }
            return editGraphics(clipID, name: "Apply Look") { $0.update(layerID) { $0.content = .text(ref: ref) } }
        case .captions:
            return false
        }
    }

    /// What a text gets from a Look (shared by applying it and by the hover preview, so both draw the same).
    static func givingLook(_ look: Look, token: String, to template: TextTemplate, animations: AnimationSet?)
        -> (template: TextTemplate, animations: AnimationSet?) {
        var template = template, anims = animations
        template.style = look.style
        template.lookID = token
        if let a = look.animation, a != .none {
            anims = a.anchor == .end ? AnimationSet(in: anims?.animationIn, out: a) : AnimationSet(in: a, out: anims?.animationOut)
        }
        return (template, anims)
    }

    /// The generator ref the target's text is stored with, and the clip that holds it (the text clip, or the graphic clip).
    func storedTextRef(_ target: LookTarget) -> (container: Clip.ID, layer: UUID, ref: GeneratorRef)? {
        switch target {
        case .textClip(let id):
            guard let clip = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
                  let ref = displayedClip(clip).generator ?? clip.generator else { return nil }
            return (id, id, ref)
        case .graphicText(let clipID, let layerID):
            guard let clip = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clipID }),
                  case .text(let ref)? = clip.graphics?.layer(layerID)?.content else { return nil }
            return (clipID, layerID, ref)
        case .captions: return nil
        }
    }

    func textContent(_ target: LookTarget) -> (TextTemplate, AnimationSet?)? {
        switch target {
        case .textClip(let id): return textContent(id)
        case .graphicText(let clipID, let layerID):
            guard let clip = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == clipID }),
                  case .text(let ref)? = clip.graphics?.layer(layerID)?.content else { return nil }
            return try? TextGenerator.decode(ref)
        case .captions: return nil
        }
    }

    private func textContent(_ id: Clip.ID) -> (TextTemplate, AnimationSet?)? {
        guard let clip = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
              let ref = displayedClip(clip).generator ?? clip.generator else { return nil }
        return try? TextGenerator.decode(ref)
    }

    private struct CurrentLookValues {
        var style: TextStyle
        var animation: KeyframeTemplate?
        var karaoke: KaraokeStyle?
        var applied: LookRef?
        /// The target still points at the applied Look itself. False for captions whose style was edited after the
        /// Look was applied: they draw a style of their own and only remember the Look (`CaptionTrack.lookID`).
        var carried = true
    }

    /// `slotOf`: the Look whose animation slot is read on a text clip (default: the applied Look). A Look animated
    /// from the end sits in the clip's out-animation, any other in its in-animation.
    private func currentLookValues(store: LookStore, slotOf other: Look? = nil) -> CurrentLookValues? {
        let target = lookTarget
        switch target {
        case .textClip, .graphicText:
            guard let target, let (t, anims) = textContent(target) else { return nil }
            let applied = t.lookID.flatMap { lookRef(token: $0, store: store) }
            let animation: KeyframeTemplate?
            if let a = (other ?? applied.flatMap { look($0, store: store) })?.animation, a != .none {
                animation = a.anchor == .end ? anims?.animationOut : (anims?.animationIn ?? t.animation)
            } else {
                animation = anims?.animationIn ?? anims?.animationOut ?? t.animation
            }
            return CurrentLookValues(style: t.style, animation: animation, applied: applied)
        case .captions:
            guard let track = activeTimeline?.captionTracks.first else { return nil }
            let styleRef = track.styleRef.isEmpty ? (track.items.first?.styleRef ?? "") : track.styleRef
            let animationRef = track.animationRef.isEmpty ? (track.items.first?.animationRef ?? "") : track.animationRef
            let lib = CaptionLookRegistry.shared.library(for: project)
            let prefix = CaptionLook.styleID(for: "")
            // The style ref names the Look itself, else the track remembers the Look its style was edited away from.
            let direct = styleRef.hasPrefix(prefix) ? lookRef(token: String(styleRef.dropFirst(prefix.count)), store: store) : nil
            let remembered = direct == nil ? track.lookID.flatMap { lookRef(token: $0, store: store) } : nil
            return CurrentLookValues(style: lib.style(for: styleRef.isEmpty ? nil : styleRef),
                                     animation: lib.animation(for: animationRef.isEmpty ? nil : animationRef),
                                     karaoke: track.karaoke, applied: direct ?? remembered, carried: direct != nil)
        case nil:
            return nil
        }
    }

    /// The Look a stored token names; an id that was merged into another Look resolves to that one.
    private func lookRef(token: String, store: LookStore) -> LookRef? {
        let kitPrefix = StyleKit.lookID("")
        if token.hasPrefix(kitPrefix) {
            let id = String(token.dropFirst(kitPrefix.count))
            if id.hasPrefix(Self.builtInLookPrefix) {
                let builtIn = String(id.dropFirst(Self.builtInLookPrefix.count))
                return LookLibrary.builtIns.contains { $0.id == builtIn } ? LookRef(scope: .builtIn, id: builtIn) : nil
            }
            return project.styleKit?.look(id) != nil && !Self.isHiddenKitLook(id) ? LookRef(scope: .project, id: id) : nil
        }
        return store.library.look(token).map { LookRef(scope: $0.isBuiltIn ? .builtIn : .user, id: $0.id) }
    }
}
