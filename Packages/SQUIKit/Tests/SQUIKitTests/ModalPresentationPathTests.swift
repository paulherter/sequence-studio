import AppKit
import Testing
@testable import SQUIKit

/// Every modal entry point (SQDialog sheet: About, Settings; SQModalSheet: Export) goes through `SQDialogWindow.present`:
/// the sheet window is clear, its scrim is clear (the dim is a separate host backdrop), it is shown at once
/// at the final frame (no settle delay).
@Suite struct ModalPresentationPathTests {
    @MainActor private func makeHost() -> NSWindow {
        let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        host.makeKeyAndOrderFront(nil)
        return host
    }

    @MainActor private func assertTree(_ w: SQDialogWindow, host: NSWindow, card: NSView) {
        #expect(w.backgroundColor == .clear)
        #expect(!w.isOpaque)
        #expect(!w.hasShadow)
        #expect(w.scrim.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(w.scrim.dimsItself == false)
        #expect(w.alphaValue == 1)                                   // shown at once, no settle delay
        let dim = host.contentView?.subviews.compactMap { $0 as? SQModalBackdropView }.first
        #expect(dim != nil)
        #expect(dim?.frame == host.contentView?.bounds)              // the dim is separate, full window, at its final frame
        #expect(dim?.alphaValue == 1)                                // the dim is on at once (dimFade is 0)
        #expect(card.superview === w.scrim)                          // the window holds only the card (and its plate)
    }

    @MainActor private func waitVisible(_ w: NSWindow) async {
        for _ in 0..<60 where w.alphaValue < 1 { try? await Task.sleep(nanoseconds: 30_000_000) }
        #expect(w.alphaValue == 1)
    }

    @MainActor @Test func dialogSheetPath() async {
        let host = makeHost()
        let d = SQDialog()
        d.messageText = "About"
        d.addButton("Done", role: .default)
        d.beginSheetModal(for: host)
        let w = d.layout()
        assertTree(w, host: host, card: w.scrim.card)
        await waitVisible(w)
        d.press(.init(0))
    }

    @MainActor @Test func cardSheetPath() async {
        let host = makeHost()
        let card = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        let sheet = SQModalSheet(card: card, size: NSSize(width: 420, height: 300)) {}
        sheet.present(over: host)
        assertTree(sheet.window, host: host, card: card)
        await waitVisible(sheet.window)
        sheet.dismiss()
    }
}
