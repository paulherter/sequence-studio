import AppKit
import SQCore
import SQEditorUI

/// Sequence > New Shape > Rectangle / Ellipse / Line: a command alias of the Create tool (E2), the item lands centered.
extension AppController {
    @objc func newShapeItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ShapeKind(rawValue: raw) else { return }
        guard session.activeTimeline != nil else { shell.statusBar.flash("Open a sequence first."); return }
        panels.createShapeAtCenter(kind)    // the Create tool's path: the item goes into a Graphic clip
    }

    /// Sequence > New Adjustment Layer (W9.6): at the playhead on a free video track, selected so effects can go on it.
    @objc func newAdjustmentLayerItem(_ sender: NSMenuItem) {
        guard session.activeTimeline != nil else { shell.statusBar.flash("Open a sequence first."); return }
        session.stopPlayback()
        guard session.addAdjustmentLayer() != nil else {
            shell.statusBar.flash(session.lastError ?? "Could not add the adjustment layer.")
            return
        }
        session.seek(to: session.playhead)
    }

    /// Sequence > New Color Matte…: asks for name, color and duration, places the matte at the playhead.
    @objc func newColorMatteItem(_ sender: NSMenuItem) {
        panels.presentNewColorMatte()     // flashes "Open a sequence first." itself
    }

    /// Sequence > New Graphics Clip (GFX): an empty graphic at the playhead, selected, with the Graphics panel in front.
    @objc func newGraphicsClipItem(_ sender: NSMenuItem) {
        guard session.activeTimeline != nil else { shell.statusBar.flash("Open a sequence first."); return }
        session.stopPlayback()
        guard panels.newGraphicsClip() else {
            shell.statusBar.flash(session.lastError ?? "Could not add the graphic.")
            return
        }
        session.seek(to: session.playhead)
    }
}
