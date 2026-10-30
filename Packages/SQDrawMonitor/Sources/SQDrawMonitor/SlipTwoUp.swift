import Foundation
import SQCore
import SQDrawKit

/// Pure layout and wording of the Slip two-up viewer (moved from SQMonitorUI so the Mac `SlipTwoUpView` and the canvas
/// monitor share it), plus the packing of both pictures into one image slot for the canvas.
public enum SlipTwoUpLayout {
    /// Height of the readout strip under the two pictures.
    public static let readoutHeight: CGFloat = 28

    /// Left (first frame) and right (last frame) picture frames inside `bounds`, flipped coordinates.
    public static func paneFrames(in bounds: CGRect, gap: CGFloat = CGFloat(DrawTheme.Spacing.sm)) -> (head: CGRect, tail: CGRect) {
        let h = max(0, bounds.height - readoutHeight - gap)
        let w = max(0, (bounds.width - gap * 3) / 2)
        return (CGRect(x: bounds.minX + gap, y: bounds.minY + gap, width: w, height: h),
                CGRect(x: bounds.minX + gap * 2 + w, y: bounds.minY + gap, width: w, height: h))
    }

    /// Slip offset in whole frames (rounded, signed).
    public static func wholeFrames(_ offset: Time, frameDuration fd: Time) -> Int {
        guard fd.value != 0, offset.timescale != 0 else { return 0 }
        let r = Double(offset.value) * Double(fd.timescale) / (Double(offset.timescale) * Double(fd.value))
        return Int(r.rounded())
    }

    /// "Slip -4 f", "Slip +12 f", "Slip 0 f".
    public static func readout(offsetFrames n: Int) -> String {
        "Slip " + (n > 0 ? "+" : "") + "\(n) f"
    }

    /// Both pictures side by side in one RGBA image (left half the first frame, right half the last), each scaled to
    /// `half` (nearest sample); a missing picture stays black. The canvas shows the halves with source rects
    /// (0, 0, 0.5, 1) and (0.5, 0, 1, 1).
    public static func pack(head: RGBAImage?, tail: RGBAImage?, half: (width: Int, height: Int)) -> RGBAImage {
        let w = max(1, half.width), h = max(1, half.height)
        var out = [UInt8](repeating: 0, count: w * 2 * h * 4)
        for i in stride(from: 3, to: out.count, by: 4) { out[i] = 255 }
        for (n, img) in [head, tail].enumerated() {
            guard let img, img.width > 0, img.height > 0, img.pixels.count >= img.width * img.height * 4 else { continue }
            for y in 0..<h {
                let sy = min(img.height - 1, y * img.height / h)
                for x in 0..<w {
                    let sx = min(img.width - 1, x * img.width / w)
                    let s = (sy * img.width + sx) * 4, d = (y * w * 2 + n * w + x) * 4
                    out[d] = img.pixels[s]; out[d + 1] = img.pixels[s + 1]; out[d + 2] = img.pixels[s + 2]; out[d + 3] = 255
                }
            }
        }
        return RGBAImage(width: w * 2, height: h, pixels: out)
    }
}

/// What the Program monitor shows during a Slip drag (the Mac `SlipTwoUpView` over the viewer): the clip's first and
/// last frame side by side with their timecodes and the slip readout. `slot` holds both pictures packed by
/// `SlipTwoUpLayout.pack`; nil while they are still decoding (black panes). Trim mode uses the same two-up for the
/// frames before and after the edit (the Mac `TrimMonitorView`): other titles, its note as the readout, the trimmed
/// side's pane outlined.
public struct SlipTwoUpPicture: Sendable, Equatable {
    public var headTimecode: String
    public var tailTimecode: String
    public var offsetFrames: Int
    public var slot: Int?
    public var headTitle = "First frame"
    public var tailTitle = "Last frame"
    /// The line under the panes; nil: the slip readout of `offsetFrames`.
    public var readout: String?
    /// Panes the edit moves (Trim mode's side): outlined in the accent color.
    public var activeHead = false, activeTail = false
    public init(headTimecode: String, tailTimecode: String, offsetFrames: Int, slot: Int? = nil) {
        self.headTimecode = headTimecode; self.tailTimecode = tailTimecode; self.offsetFrames = offsetFrames; self.slot = slot
    }

    /// Trim mode's two-up: the last frame before the edit and the first after it ("--" where a side has no clip).
    public static func trim(outgoingTimecode: String?, incomingTimecode: String?, outgoingActive: Bool, incomingActive: Bool,
                            note: String, slot: Int? = nil) -> SlipTwoUpPicture {
        var p = SlipTwoUpPicture(headTimecode: outgoingTimecode ?? "--", tailTimecode: incomingTimecode ?? "--",
                                 offsetFrames: 0, slot: slot)
        p.headTitle = "Before the edit"; p.tailTitle = "After the edit"
        p.readout = note
        p.activeHead = outgoingActive; p.activeTail = incomingActive
        return p
    }
}

extension MonitorPanel {
    /// The two-up instead of the picture: two bordered panes with "First frame" / "Last frame" and their timecodes on
    /// HUD plates, the readout centered below.
    func drawSlipTwoUp(_ c: inout Canvas, _ two: SlipTwoUpPicture) {
        let t = theme
        c.fill(slot, t.monitorBackdrop)
        let panes = SlipTwoUpLayout.paneFrames(in: slot)
        let inset = CGFloat(DrawTheme.Spacing.xs + DrawTheme.Spacing.xxs)
        for (i, pane) in [panes.head, panes.tail].enumerated() where pane.width > 2 && pane.height > 2 {
            c.fill(pane, .black)
            if let s = two.slot {
                // The picture fitted in the pane at the sequence's aspect.
                let aspect = sequenceSize.height > 0 ? sequenceSize.width / sequenceSize.height : 16.0 / 9
                var w = pane.width, h = w / aspect
                if h > pane.height { h = pane.height; w = h * aspect }
                let pic = CGRect(x: pane.midX - w / 2, y: pane.midY - h / 2, width: w, height: h)
                c.draw(imageSlot: s, in: pic, source: i == 0 ? (0, 0, 0.5, 1) : (0.5, 0, 1, 1))
            }
            let active = i == 0 ? two.activeHead : two.activeTail
            c.stroke(polygon: TransformOverlay.corners(pane), width: active ? 2 : 1, active ? t.accent : t.separator)
            for (text, top) in [(i == 0 ? two.headTitle : two.tailTitle, true), (i == 0 ? two.headTimecode : two.tailTimecode, false)] {
                let size = c.size(of: text, fontSize: 11)
                let r = CGRect(x: pane.minX + inset, y: top ? pane.minY + inset : pane.maxY - inset - 16,
                               width: size.width + 8, height: 16)
                c.fill(r, t.viewerHUD)
                c.draw(text, in: r, fontSize: 11, t.label2, inset: 4)
            }
        }
        let gap = CGFloat(DrawTheme.Spacing.sm)
        let readout = two.readout ?? SlipTwoUpLayout.readout(offsetFrames: two.offsetFrames)
        guard !readout.isEmpty else { return }
        c.draw(readout,
               in: CGRect(x: slot.minX + gap, y: slot.maxY - SlipTwoUpLayout.readoutHeight, width: max(0, slot.width - gap * 2),
                          height: 18),
               fontSize: 11, t.label2, align: .center)
    }
}
