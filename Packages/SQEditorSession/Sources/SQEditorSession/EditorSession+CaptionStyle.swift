import Foundation
import SQCore
import SQLibrary
import SQText
import SQTranscribe

/// Caption style of the track, per-caption overrides and the karaoke word highlight. One undo step per call.
extension EditorSession {
    /// The karaoke style of the first caption track that has one (nil: off everywhere).
    public var captionKaraoke: KaraokeStyle? { activeTimeline?.captionTracks.lazy.compactMap(\.karaoke).first }

    /// Turns the word highlight on (a style) or off (nil) for every caption track.
    @discardableResult
    public func setCaptionKaraoke(_ karaoke: KaraokeStyle?) -> Bool {
        guard let tl = activeTimeline, !tl.captionTracks.isEmpty else { return false }
        let ids = tl.captionTracks.map(\.id)
        return attempt(karaoke == nil ? "Word Highlight Off" : "Word Highlight") { t in
            for id in ids { try t.setCaptionKaraoke(karaoke, track: id) }
        }
    }

    /// The selected captions get their own style (the track style no longer changes them); nil hands them back.
    @discardableResult
    public func setSelectedCaptionStyle(_ styleRef: String?) -> Bool {
        guard !captionSelection.isEmpty else { return false }
        let ids = captionSelection
        return attempt(styleRef == nil ? "Use Track Style" : "Caption Style") { try $0.setCaptionItemStyle(ids, styleRef: styleRef) }
    }

    /// True when any selected caption has a style of its own.
    public var selectedCaptionsHaveOwnStyle: Bool {
        let ids = captionSelection
        return captionItems.contains { ids.contains($0.id) && $0.styleOverridden }
    }
}

// MARK: - Caption Looks (style + animation + segmentation: Looks of the one Look store)

extension EditorSession {
    /// Registers `look` under `id` and gives every caption of every caption track its style and animation (one undo step).
    /// Captions in `releasing` (default: the selected ones, the source of an edit) lose their own-style override in the
    /// same undo step, so the push reaches them too.
    @discardableResult
    public func pushCaptionLook(_ look: CaptionLook, id: String, releasing: Set<CaptionItem.ID>? = nil) -> Bool {
        guard let tl = activeTimeline, !tl.captionTracks.isEmpty else { return false }
        let refs = CaptionLookRegistry.shared.register(look, id: id)
        let trackIDs = tl.captionTracks.map(\.id)
        let release = releasing ?? captionSelection
        return attempt("Caption Look") { t in
            for tid in trackIDs { try t.setCaptionStyle(styleRef: refs.styleRef, animationRef: refs.animationRef, track: tid) }
            try t.setCaptionItemStyle(release, styleRef: nil)
        }
    }

    /// The look of the selected caption (first one), or of the first caption when none is selected: what "Update Look"
    /// pushes to the track after one caption was edited.
    public func currentCaptionLook() -> CaptionLook? {
        let items = captionItems
        guard let c = items.first(where: { captionSelection.contains($0.id) }) ?? items.first else { return nil }
        let lib = CaptionPresetLibrary.builtIn
        return CaptionLook(style: lib.style(for: c.styleRef.isEmpty ? nil : c.styleRef),
                           animation: lib.animation(for: c.animationRef.isEmpty ? nil : c.animationRef))
    }

    /// Animation of the single selected text clip (its in-animation, else its out-animation); nil if no text clip is
    /// selected or it has no animation. A text animator (per character / word / line) counts as an animation and travels
    /// with it, so captions animate by word like the text clip (W7.3).
    public func animationFromSelectedTextClip() -> KeyframeTemplate? {
        guard selection.count == 1, let id = selection.first,
              let clip = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
              let ref = clip.generator, let (template, anims) = try? TextGenerator.decode(ref) else { return nil }
        // The first side that actually animates: an empty in-animation must not hide the out-animation.
        func animates(_ t: KeyframeTemplate?) -> Bool { t.map { $0 != .none && (!$0.tracks.isEmpty || $0.textAnimator != nil) } ?? false }
        return [anims?.animationIn, anims?.animationOut, template.animation].lazy.compactMap { $0 }.first(where: animates)
    }
}

/// A saved Look as the caption panels use it: style, animation and the segmentation it was made with.
public struct StoredCaptionLook: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var look: CaptionLook
    public var segmentation: CaptionPreset
}

/// Payload of an old `.caption` preset: the look plus its segmentation (an absent segmentation reads as `.standard`).
/// Read by the one-time import into the Look store and written for the Library panel's copy.
public struct CaptionLookPayload: Codable {
    public static let version = 1
    public var look: CaptionLook
    public var segmentation: CaptionPreset?
    /// The Look's group in the Look strip filter; only set when a Look is exported (an optional key older builds ignore).
    public var category: String?

    public init(look: CaptionLook, segmentation: CaptionPreset?, category: String? = nil) {
        self.look = look; self.segmentation = segmentation; self.category = category
    }
}

/// The caption panels' view of the Look store (`LookStore`): the user's Looks with a segmentation, and the default look
/// Create Captions applies. Every saved Look is listed (one saved in the Text panel has no animation and the standard
/// segmentation).
@MainActor
public final class CaptionLookLibrary {
    public static let shared = CaptionLookLibrary(looks: .shared, legacy: LibraryStores.presetStore, defaults: .standard)
    static let defaultKey = "sq.captionLook.default"

    public private(set) var looks: [StoredCaptionLook] = []
    private let store: LookStore
    /// The preset store that held the caption looks before the Look store: imported once on `reload`. New and changed
    /// Looks are still copied there so the Library panel's Captions group keeps listing them.
    private let legacy: PresetStore?
    private let defaults: UserDefaults
    /// The `LookStore.didChange` observer, removed when the library goes away (a store outlives its libraries).
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    /// Observers still installed (tests check that a library removes its own).
    nonisolated(unsafe) static var liveObservers = 0

    public init(looks store: LookStore, legacy: PresetStore? = nil, defaults: UserDefaults) {
        self.store = store; self.legacy = legacy; self.defaults = defaults
        refresh()
        // A Look saved, changed or deleted anywhere (the Text panel) shows in the caption panels at once.
        Self.liveObservers += 1
        observer = NotificationCenter.default.addObserver(forName: LookStore.didChange, object: store, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer); Self.liveObservers -= 1 } }

    /// A library with a Look store of its own in memory (tests, previews); `store` is the old preset store to import.
    public convenience init(store: PresetStore?, defaults: UserDefaults) {
        self.init(looks: LookStore(url: nil, registry: .shared), legacy: store, defaults: defaults)
    }

    public var defaultLookID: UUID? {
        get { defaults.string(forKey: Self.defaultKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.defaultKey) }
    }

    public var defaultLook: StoredCaptionLook? { defaultLookID.flatMap { id in looks.first { $0.id == id } } }

    /// Takes the old caption presets in (first call only) and reads the Look store. The store registers every Look so
    /// captions that carry its refs render.
    public func reload() async {
        await store.importCaptionPresets(from: legacy)
        refresh()
    }

    private func refresh() {
        let lib = store.library
        looks = lib.user.compactMap { l in
            UUID(uuidString: l.id).map {
                StoredCaptionLook(id: $0, name: l.name, look: l.captionLook, segmentation: LookStore.segmentation(of: l) ?? .standard)
            }
        }
        // The default look was merged into an equal Look: follow it.
        if let d = defaultLookID, !looks.contains(where: { $0.id == d }),
           let kept = lib.look(d.uuidString).flatMap({ UUID(uuidString: $0.id) }) {
            defaultLookID = kept
        }
    }

    public enum SaveError: Error, Equatable, Sendable { case emptyName }

    /// Saves a new Look. Throws `SaveError.emptyName` for a blank name: nothing is saved, the default stays.
    @discardableResult
    public func save(name: String, look: CaptionLook, segmentation: CaptionPreset, makeDefault: Bool = false) async throws -> UUID {
        let id = UUID()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = try store.edit {
            $0.add(name: name, style: look.style, animation: look.animation,
                   captionSegmentation: LookStore.encode(segmentation), id: id.uuidString)
        }
        guard added != nil else { throw SaveError.emptyName }
        if let payload = try? JSONEncoder().encode(CaptionLookPayload(look: look, segmentation: segmentation)) {
            try? await legacy?.add(PresetItem(id: id, kind: .caption, name: name, payload: payload, payloadVersion: CaptionLookPayload.version))
            if let written = await legacy?.preset(id) { store.recordPreset(written) }
        }
        if makeDefault { defaultLookID = id }
        refresh()
        return id
    }

    /// Replaces the look (and the segmentation, when given) of a saved look. An id that was merged into another Look
    /// changes that Look. An unknown id changes nothing, here and in the old preset store.
    public func update(_ id: UUID, look: CaptionLook, segmentation: CaptionPreset?) async throws {
        let found = try store.edit {
            $0.update(id.uuidString) { l in
                (l.style, l.animation) = (look.style, look.animation)
                if let segmentation { l.captionSegmentation = LookStore.encode(segmentation) }
            }
        }
        refresh()
        guard found, let kept = store.library.look(id.uuidString) else { return }
        let seg = segmentation ?? LookStore.segmentation(of: kept)
        if let payload = try? JSONEncoder().encode(CaptionLookPayload(look: look, segmentation: seg)) {
            for pid in Set([id, UUID(uuidString: kept.id) ?? id]) {
                try? await legacy?.updatePayload(pid, payload: payload, version: CaptionLookPayload.version)
                if let written = await legacy?.preset(pid) { store.recordPreset(written) }
            }
        }
    }

    /// Deletes a saved look. An id that was merged into another Look only stops resolving: that Look stays.
    public func delete(_ id: UUID) async throws {
        try store.edit { _ = $0.delete(id.uuidString) }
        try? await legacy?.delete(id)
        store.forgetPreset(id)
        if defaultLookID == id { defaultLookID = nil }
        refresh()
    }

    /// Refs of a saved look (style, animation) as captions carry them.
    public static func refs(of id: UUID) -> (styleRef: String, animationRef: String) {
        (CaptionLook.styleID(for: id.uuidString), CaptionLook.animationID(for: id.uuidString))
    }

    /// The preset Create Captions uses: the default look's segmentation and refs when one is set, else `preset` unchanged
    /// (the built-in presets already carry the default look; "No Animation" stays none).
    public func applyDefault(to preset: CaptionPreset) -> CaptionPreset {
        if let l = defaultLook {
            var p = l.segmentation
            (p.styleRef, p.animationRef) = Self.refs(of: l.id)
            return p
        }
        return preset
    }
}
