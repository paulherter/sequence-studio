import Testing
@testable import SQEditorSession

struct DeleteKeyPolicyTests {
    @Test func textAndListsKeepTheirOwnDelete() {
        #expect(DeleteKeyPolicy.route(responder: .editableText, routerConsumed: false, routerHasActions: false) == .passToResponder)
        #expect(DeleteKeyPolicy.route(responder: .deletingList, routerConsumed: false, routerHasActions: false) == .passToResponder)
    }

    @Test func routerHandledDeleteIsSwallowed() {
        #expect(DeleteKeyPolicy.route(responder: .other, routerConsumed: true, routerHasActions: true) == .consume)
        // Auto-repeat of a non-repeatable delete: consumed without an action, must not reach NSResponder.keyDown.
        #expect(DeleteKeyPolicy.route(responder: .other, routerConsumed: true, routerHasActions: false) == .consume)
    }

    @Test func unmappedDeleteInAnyPanelGoesThroughTheMenuNotTheResponderChain() {
        // Effect Controls, Graphics, Captions, Keystones have no router binding; any first responder, not only the timeline.
        #expect(DeleteKeyPolicy.route(responder: .other, routerConsumed: false, routerHasActions: false) == .menuThenBeepIfRefused)
        #expect(DeleteKeyPolicy.swallow(menuHandled: true))       // success: silent
        #expect(!DeleteKeyPolicy.swallow(menuHandled: false))     // genuine refusal keeps the beep
    }

    @Test func premiereMapBindsDeleteOnlyInTimelineAndProject() {
        // The reason the menu path exists: every other panel has no Delete binding in the router.
        let b = KeyBinding(.delete, [])
        #expect(CommandMap.premiereDefault.command(for: b, focus: .timeline) == .delete)
        #expect(CommandMap.premiereDefault.command(for: b, focus: .effectControls) == nil)
        #expect(CommandMap.premiereDefault.command(for: b, focus: .graphics) == nil)
    }
}
