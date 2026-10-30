import Foundation

// v82: the pixel shape of a sequence (Sequence Settings > Pixel Shape). Stored only when not square, so square sequences
// encode, render and export exactly as before; a non-square one makes the file v82 (ProjectFile+V82.swift).
//
// Contract: `width` x `height` stay the stored pixel size (render targets, scopes, export). Everything a user can place
// (Scale, Position, graphics, text, masks, handles) lives in DISPLAY space: `displayWidth` x `height`, the picture as it is
// shown. The compositor draws display space into the stored pixels, which squeezes it horizontally by width / displayWidth.

extension SequenceFormat {
    /// The shape of one stored pixel (default square).
    public var pixelAspect: PixelAspect {
        get { pixelAspectStore ?? .square }
        set { pixelAspectStore = newValue.isSquare ? nil : newValue }
    }

    /// Width in pixels of the picture as shown (even, see `PixelAspect.displayWidth`); `width` for square pixels.
    public var displayWidth: Int { pixelAspectStore?.displayWidth(ofStored: width) ?? width }

    /// Display size as a double pair, the frame user-facing geometry is computed in.
    public var displaySize: (width: Double, height: Double) { (Double(displayWidth), Double(height)) }

    /// A square-pixel format of the display size: what layout code (text, captions, graphics, date stamp) reads as "the canvas".
    /// `self` for square pixels.
    public var layoutFormat: SequenceFormat {
        guard pixelAspectStore != nil else { return self }
        var f = self
        f.width = displayWidth
        f.pixelAspectStore = nil
        return f
    }

    /// The same stored size with square pixels: for passes that work on the target's own pixels (transition canvases).
    public var storedPixels: SequenceFormat {
        guard pixelAspectStore != nil else { return self }
        var f = self
        f.pixelAspectStore = nil
        return f
    }
}
