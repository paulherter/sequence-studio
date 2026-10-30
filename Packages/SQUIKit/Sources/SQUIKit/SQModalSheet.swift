import AppKit

/// Presents an own card (Relink, Import Report, Export...) in the modal shell: the same centered card over a 35 % scrim as
/// `SQDialog`, as a child window of `host`. The card is styled here (panel fill, radius 14, edge, drop shadow); Esc and Cmd-. call
/// `onCancel`, all other keys go to the card (its buttons' key equivalents, its fields).
@MainActor
public final class SQModalSheet {
    public let window: SQDialogWindow
    private weak var host: NSWindow?
    private var resizeToken: NSObjectProtocol?

    /// `size`: the card's size; nil takes its fitting size.
    public init(card: NSView, size: NSSize? = nil, onCancel: @escaping @MainActor () -> Void) {
        card.wantsLayer = true
        SQDialogStyle.styleCard(card.layer)
        window = SQDialogWindow(card: card, size: size)
        window.onCancel = onCancel
    }

    public func present(over host: NSWindow) {
        self.host = host
        window.present(over: host, path: "SQModalSheet")
        resizeToken = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: host, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let host = self.host { self.window.setFrame(host.frame, display: true) } }
        }
    }

    /// The card's content changed size: re-centers it.
    public func resizeCard(to size: NSSize? = nil) {
        let card = window.scrim.card
        window.scrim.setCardSize(size ?? card.fittingSize)
    }

    public func dismiss() {
        if let resizeToken { NotificationCenter.default.removeObserver(resizeToken) }
        resizeToken = nil
        window.closeFaded(from: host)
        host?.makeKey()
        host = nil
    }
}

/// Menu commands and shortcuts stay off while a dialog or sheet is up: Cmd+Z, Delete or a panel shortcut must not edit the
/// project behind a dialog that is waiting for an answer.
public enum SQModalGate {
    public static func blocksCommands(attachedSheet: Bool, appModal: Bool) -> Bool { attachedSheet || appModal }
}

extension NSWindow {
    /// The dialog shell covering this window, if any. Dialogs are child windows of the window they cover (a system sheet
    /// would hide the window's content behind it), so `attachedSheet` no longer sees them.
    public var sqAttachedSheet: NSWindow? { childWindows?.last { $0 is SQDialogWindow } ?? attachedSheet }
}
