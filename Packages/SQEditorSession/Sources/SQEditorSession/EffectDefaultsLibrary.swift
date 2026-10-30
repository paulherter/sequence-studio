import Foundation
import Observation
import SQCore
import SQLibrary

/// FB-W: the app's one copy of the user's effect and transition defaults (`Library/defaults.json`). Every change is
/// written first, then kept, then announced with `didChange` so sessions, Effect Controls and Preferences follow.
@MainActor @Observable
public final class EffectDefaultsLibrary {
    public static let didChange = Notification.Name("sq.effectDefaultsDidChange")

    public static let shared = EffectDefaultsLibrary(
        fileURL: EffectDefaultsFile.fileURL(applicationSupport: PresetStore.defaultApplicationSupport()))

    public private(set) var defaults: EffectDefaults
    /// nil = memory only (tests).
    @ObservationIgnored public let fileURL: URL?
    /// Set when the file could not be read (a newer app wrote it): saving is refused so it is not overwritten.
    @ObservationIgnored public private(set) var readOnly = false

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL else { defaults = EffectDefaults(); return }
        do { defaults = try EffectDefaultsFile.load(fileURL) } catch {
            defaults = EffectDefaults()
            readOnly = true
        }
    }

    /// Applies `change`; nothing happens (and false) when the file cannot be written.
    @discardableResult
    public func update(_ change: (inout EffectDefaults) -> Void) -> Bool {
        var next = defaults
        change(&next)
        guard next != defaults else { return true }
        if let fileURL {
            guard !readOnly, (try? EffectDefaultsFile.save(next, to: fileURL)) != nil else { return false }
        }
        defaults = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return true
    }

    /// Takes a whole new set (what a session or Effect Controls computed).
    @discardableResult
    public func replace(with new: EffectDefaults) -> Bool { update { $0 = new } }
}
