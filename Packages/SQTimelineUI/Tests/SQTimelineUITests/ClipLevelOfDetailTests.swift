import AppKit
import Foundation
import Testing
@testable import SQTimelineUI

/// Level of detail (the design notes 2026-10-11): a clip under 3 pt on screen is a plain filled rect; 3 pt and wider keep
/// the full draw (chrome, name, waveform), which `TimelineFastDrawTests` pins pixel for pixel.
@MainActor @Suite(.serialized) struct ClipLevelOfDetailTests {
    @Test func thresholdIsThreePoints() {
        #expect(ClipDrawing.isSimple(width: 2))
        #expect(ClipDrawing.isSimple(width: 2.99))
        #expect(!ClipDrawing.isSimple(width: 3))
        #expect(!ClipDrawing.isSimple(width: 40))
    }

    private func render(_ body: () -> Void) -> [UInt8] {
        let w = 40, h = 40
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let cg = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            body()
            NSGraphicsContext.restoreGraphicsState()
        }
        return bytes
    }

    /// A simple clip is one flat color over its body rows and leaves the rest of the row alone.
    @Test func simpleClipIsOneFlatRect() {
        let rect = CGRect(x: 10, y: 4, width: 2, height: 30)
        let bytes = render { ClipDrawing.drawSimple(rect: rect, style: .video, isSelected: false, isOffline: false) }
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * 40 + x) * 4..<(y * 40 + x) * 4 + 4]) }
        #expect(px(10, 10) == px(11, 20))
        #expect(px(10, 10)[3] == 255)
        #expect(px(9, 10)[3] == 0 && px(12, 10)[3] == 0)
        #expect(px(10, 4)[3] == 0 && px(10, 34)[3] == 0)        // the body is inset 1 pt top and bottom
    }

    /// A 3 pt clip is not drawn by the simple path: its edge line makes the result differ.
    @Test func threePointClipTakesFullDraw() {
        let rect = CGRect(x: 10, y: 4, width: 3, height: 30)
        let full = render { ClipDrawing.draw(name: "A", rect: rect, visible: CGRect(x: 0, y: 0, width: 40, height: 40), style: .video,
                                             isSelected: false, isOffline: false) }
        let simple = render { ClipDrawing.drawSimple(rect: rect, style: .video, isSelected: false, isOffline: false) }
        #expect(full != simple)
    }
}
