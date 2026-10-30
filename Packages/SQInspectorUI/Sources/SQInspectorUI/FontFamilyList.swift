import AppKit
import CoreText
import Synchronization
import SQText

/// Installed font families for the text inspector popups. The first `NSFontManager.availableFontFamilies` call costs
/// ~70-100 ms on the main thread at launch (the text inspector is built before the first window), so `warm()` reads
/// the same list through CoreText on a background thread (CTFontManager is thread-safe; AppKit's list is CoreText's
/// sorted case-insensitively, pinned by FontFamilyListTests). A font set change drops the cache and falls back to AppKit.
public enum FontFamilyList {
    private static let cache = Mutex<[String]?>(nil)
    private static let pending = DispatchGroup()
    @MainActor private static var warming = false
    @MainActor private static var observing = false

    /// Starts the background read (idempotent). Call early at launch.
    @MainActor public static func warm() {
        observe()
        guard !warming, cache.withLock({ $0 }) == nil else { return }
        warming = true
        pending.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let list = fetch()
            cache.withLock { $0 = list }
            pending.leave()
        }
    }

    /// The family names, sorted like AppKit sorts them.
    @MainActor public static var current: [String] {
        if let list = cache.withLock({ $0 }) { return list }
        if warming {
            pending.wait()       // the background read is already running (tens of ms): wait instead of reading twice
            warming = false
            if let list = cache.withLock({ $0 }) { return list }
        }
        return NSFontManager.shared.availableFontFamilies
    }

    nonisolated static func fetch() -> [String] {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        return names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    @MainActor private static func observe() {
        guard !observing else { return }
        observing = true
        let drop: @Sendable (Notification) -> Void = { _ in cache.withLock { $0 = nil } }
        NotificationCenter.default.addObserver(forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
                                               object: nil, queue: nil) { n in
            drop(n)
            TextGenerator.resetFailedLayouts()      // a text that failed for a missing font is tried again
        }
        NotificationCenter.default.addObserver(forName: NSFont.fontSetChangedNotification, object: nil, queue: nil, using: drop)
    }
}
