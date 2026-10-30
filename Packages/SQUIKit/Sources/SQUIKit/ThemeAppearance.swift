import AppKit
import Observation
import Synchronization
import SwiftUI

extension PaletteColor {
    var ns: NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
}

extension Theme {
    /// Posted (main thread) after the Appearance changed; every view has been told to redraw by then.
    public static let appearanceDidChange = Notification.Name("sq.appearanceDidChange")

    /// The palette every dynamic Theme color reads. Locked, because colors resolve on any thread (CA, render helpers).
    static let livePalette = Mutex(AppearancePalette.resolve(.standard))
    static var palette: AppearancePalette { livePalette.withLock { $0 } }

    /// A Theme color that follows the Appearance setting: resolved from the live palette each time it is drawn.
    static func dynamic(_ pick: @escaping @Sendable (AppearancePalette) -> PaletteColor) -> NSColor {
        NSColor(name: nil) { _ in pick(Theme.livePalette.withLock { $0 }).ns }
    }
    /// `ink` (white in dark, black in light) at a dark-mode fill alpha.
    static func inkFill(_ darkAlpha: Double) -> NSColor { dynamic { $0.ink.withAlpha($0.fillAlpha(darkAlpha)) } }
    /// `ink` at a dark-mode hairline alpha, scaled by Contrast.
    static func inkLine(_ darkAlpha: Double) -> NSColor { dynamic { $0.ink.withAlpha($0.lineAlpha(darkAlpha)) } }
    /// A fixed alpha of `ink` (not scaled).
    static func ink(_ alpha: Double) -> NSColor { dynamic { $0.ink.withAlpha(alpha) } }

    /// System appearance that matches the mode (text cursor, scrollers, SwiftUI color scheme).
    @MainActor public static var windowAppearance: NSAppearance? {
        NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
    }
}

/// The Appearance setting (design B v7 popover): Dark / Light, Background, Contrast. Persisted in UserDefaults as
/// `sq.appearance.*`, applied live: every window redraws, own views get `viewDidChangeEffectiveAppearance`.
@MainActor @Observable
public final class ThemeAppearance {
    public static let shared = ThemeAppearance()

    public private(set) var settings: AppearanceSettings
    /// Bumped on every change; SwiftUI roots read it through `sqLiveAppearance()`.
    public private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = AppearanceSettings(defaults: defaults)
        Theme.livePalette.withLock { $0 = AppearancePalette.resolve(settings) }
    }

    public var palette: AppearancePalette { Theme.palette }

    public func update(_ change: (inout AppearanceSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let modeChanged = s.mode != settings.mode
        settings = s
        s.save(to: defaults)
        Theme.livePalette.withLock { $0 = AppearancePalette.resolve(s) }
        revision += 1
        apply(modeChanged: modeChanged)
        NotificationCenter.default.post(name: Theme.appearanceDidChange, object: self)
    }

    public func reset() { update { $0.background = 0; $0.contrast = 50 } }

    /// Sets the system appearance once at launch (call before the first window shows).
    public func applyAtLaunch() { NSApp?.appearance = Theme.windowAppearance }

    private func apply(modeChanged: Bool) {
        let ap = Theme.windowAppearance
        if modeChanged { NSApp?.appearance = ap }
        for w in NSApp?.windows ?? [] {
            if modeChanged, w.appearance != nil { w.appearance = ap }
            if let bg = w.backgroundColor { w.backgroundColor = bg }
            if let v = w.contentView { Self.refresh(v) }
            w.contentView?.superview.map { $0.needsDisplay = true }
            w.invalidateShadow()
        }
    }

    /// Redraws `view` and its subviews; own (non-system) views also re-run `viewDidChangeEffectiveAppearance`, where
    /// layer colors are copied.
    static func refresh(_ view: NSView) {
        view.needsDisplay = true
        view.needsLayout = true
        if isOwnClass(type(of: view)) { view.viewDidChangeEffectiveAppearance() }
        for s in view.subviews { refresh(s) }
    }

    private static func isOwnClass(_ c: AnyClass) -> Bool {
        !Bundle(for: c).bundlePath.hasPrefix("/System")
    }
}

private struct LiveAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content.id(ThemeAppearance.shared.revision)
    }
}

public extension View {
    /// Rebuilds this SwiftUI tree when the Appearance changes (its Theme colors are resolved again).
    func sqLiveAppearance() -> some View { modifier(LiveAppearance()) }
}
