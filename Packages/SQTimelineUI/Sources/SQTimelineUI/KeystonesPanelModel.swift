import Foundation
import Observation
import SQCore
import SQLibrary
import SQUIKit

// Portable (Windows builds it too): the Mac pasteboard part of keystones stays in KeystoneSupport.swift.

/// Keystones panel content: built-ins plus the user's `.keystone` presets (kept in step with the Library by the app).
@MainActor @Observable
public final class KeystonesPanelModel {
    /// The Library's presets (every kind; only `.keystone` is read).
    public var presets: [PresetItem] = [] { didSet { decoded = nil } }
    public var selectedID: UUID?
    /// `presets` decoded, until they change: the panel, the Intro / Outro popups and every refresh read the list.
    @ObservationIgnored private var decoded: [Keystone]?
    /// Saves (adds or replaces) a keystone in the Library.
    @ObservationIgnored public var onSave: ((Keystone) -> Void)?
    /// Saves like `onSave` but answers after the Library holds it (true) or could not store it (false). The app sets
    /// this one: its Library stores asynchronously. Without it `onSave` is taken to store at once.
    @ObservationIgnored public var onSaveStored: ((Keystone) async -> Bool)?
    /// Deletes the Library preset with this id (a user keystone, or a built-in's saved changes).
    @ObservationIgnored public var onDelete: ((UUID) -> Void)?

    public init() {}

    public var keystones: [Keystone] {
        let items = presets                 // read even on a hit: observers follow the Library
        if let decoded { return decoded }
        let all = KeystoneLibrary.keystones(from: items)
        decoded = all
        return all
    }

    /// The user's saved animations for a side (`AnimationChoices`): keystones that start or end with the clip.
    public func savedAnimations(_ side: AnimationSide) -> [Keystone] {
        keystones.filter { !$0.isBuiltIn && $0.animationSide == side }
    }
    /// What the Intro / Outro popups offer for a side: the built-in keystones first, then the saved ones, each id once
    /// (a built-in with saved changes stands in its own place), a built-in never under a name an earlier entry has.
    public func offeredAnimations(_ side: AnimationSide) -> [Keystone] {
        var ids = Set<UUID>(), builtInNames = Set<String>()
        var out: [Keystone] = []
        for k in keystones where k.animationSide == side && ids.insert(k.id).inserted {
            if k.isBuiltIn, !builtInNames.insert(k.name.lowercased()).inserted { continue }
            out.append(k)
        }
        return out
    }

    /// Saves in the Library and tells whether the keystone is stored now (listed in `keystones`): the app stores
    /// asynchronously (`onSaveStored` answers once it did), a plain `onSave` stores at once. A save that did not happen
    /// is false, so no caller shows a result the Library does not have.
    public func save(_ k: Keystone) async -> Bool {
        if let onSaveStored { guard await onSaveStored(k) else { return false } }
        else if let onSave { onSave(k) }
        else { return false }
        return keystones.contains { $0.id == k.id }
    }

    /// True when a keystone can be saved here.
    public var canSave: Bool { onSave != nil || onSaveStored != nil }

    /// The selected keystone; a hidden built-in whose saved changes were deleted still resolves (`keystone(id:from:)`).
    public var selected: Keystone? {
        guard let id = selectedID else { return nil }
        return keystones.first { $0.id == id } ?? KeystoneLibrary.keystone(id: id, from: presets)
    }

    /// A user keystone, or a built-in with saved changes (deleting restores the built-in).
    public func canDelete(_ id: UUID) -> Bool { KeystoneLibrary.isCustomised(id, in: presets) }

    /// Sets (nil = clears) the keystone's own curve and saves it.
    public func setEasing(_ curve: EasingCurve?, for id: UUID) {
        guard var k = keystones.first(where: { $0.id == id }) else { return }
        k.easing = curve
        onSave?(k)
    }

    /// Short description for the list: properties and length.
    public nonisolated static func subtitle(_ k: Keystone) -> String {
        let props = Keystone.Property.allCases.filter { k.properties.contains($0) }.map { p -> String in
            switch p {
            case .position: "Position"
            case .scale: "Scale"
            case .rotation: "Rotation"
            case .opacity: "Opacity"
            }
        }
        let ms = Int((Double(k.duration.value) / Double(k.duration.timescale) * 1000).rounded())
        let len = ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
        return props.joined(separator: ", ") + " · " + len + (k.easing != nil ? " · custom curve" : "")
    }

    public static func symbol(_ k: Keystone) -> SQIcon {
        let p = k.properties
        if p.contains(.rotation) { return .rotateCW }
        if p.contains(.position) { return .moveHorizontal }
        if p.contains(.scale) { return .maximize }
        return .contrast
    }
}
