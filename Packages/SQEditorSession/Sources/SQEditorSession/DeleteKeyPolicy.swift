import Foundation

/// What the app's key monitor does with a Delete / Forward-Delete key event that the KeyRouter has no action for.
/// An unconsumed key down travels to NSWindow, finds no handler and plays the system error beep, so a *successful* delete
/// (done through the Edit menu item, a table's own key handling, ...) must always swallow the event; only a genuine refusal
/// (nothing deletable here: the menu item is disabled) lets it through for the beep.
public enum DeleteKeyPolicy {
    public enum Route: Equatable, Sendable {
        /// Leave the event to the responder (an editable text view or a list that deletes by itself).
        case passToResponder
        /// The router already handled or deliberately swallowed it.
        case consume
        /// Try the Edit menu's Delete item: handled -> consume silently; refused -> pass on (error beep is the refusal feedback).
        case menuThenBeepIfRefused
    }

    public enum Responder: Equatable, Sendable { case editableText, deletingList, other }

    public static func route(responder: Responder, routerConsumed: Bool, routerHasActions: Bool) -> Route {
        if responder != .other { return .passToResponder }
        if routerConsumed || routerHasActions { return .consume }
        return .menuThenBeepIfRefused
    }

    /// True = the menu did the delete: swallow the key down (and its key up) silently.
    public static func swallow(menuHandled: Bool) -> Bool { menuHandled }
}
