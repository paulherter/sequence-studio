import Foundation
import SQCore
import SQExport

/// Pure maths of the export preview (the Mac `ExportPreviewModel` and the shared `ShellExportPreview`).
public enum ExportPreviewMath {
    /// Frame index under a 0...1 position of the scrub bar (clamped; 0 for an empty source).
    public static func index(fraction: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return Int((min(max(fraction, 0), 1) * Double(count - 1)).rounded())
    }

    public static func fraction(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return min(max(Double(index) / Double(count - 1), 0), 1)
    }

    /// The preview renders what the export would, but small (longest side <= `maxSide`, even, never scaled up) and without audio.
    public static func previewSettings(from s: ExportSettings, maxSide: Int = 640) -> ExportSettings {
        var p = s
        let w = max(s.video.width, 2), h = max(s.video.height, 2)
        let longest = max(w, h)
        if longest > maxSide {
            p.video.width = max(2, (w * maxSide / longest) & ~1)
            p.video.height = max(2, (h * maxSide / longest) & ~1)
        } else {
            p.video.width = w & ~1; p.video.height = h & ~1
        }
        p.audio.enabled = false
        p.audio.loudness = nil
        return p
    }

    /// The picture rect inside the viewer box: the output's aspect (16:9 when unknown), fitted and centered
    /// (`ExportDialogView.layoutPicture`).
    public static func pictureRect(box: CGRect, width: Int, height: Int) -> CGRect {
        let aspect = height > 0 && width > 0 ? CGFloat(width) / CGFloat(height) : 16.0 / 9.0
        var w = box.width, h = box.width / aspect
        if h > box.height { h = box.height; w = h * aspect }
        return CGRect(x: box.minX + ((box.width - w) / 2).rounded(), y: box.minY + ((box.height - h) / 2).rounded(),
                      width: w.rounded(), height: h.rounded())
    }
}
