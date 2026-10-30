import AppKit

/// The picture area of the Program monitor: it holds the viewer slot (picture, overlays, badges). The monitor shows only
/// the preview and on-canvas creation; text Looks live in Controls.
@MainActor
final class PictureAreaView: NSView {
    /// The viewer slot's bottom constraint (constant is negative); the monitor updates it with the zoom.
    var viewerBottom: NSLayoutConstraint?
    /// Space between this area and the viewer slot.
    var viewerMargin: CGFloat = 0
}
