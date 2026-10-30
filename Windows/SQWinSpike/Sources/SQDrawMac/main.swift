// Mac renderer for the shared draw list (CoreGraphics, rectangles only). Usage: SQDrawMac out.png [playheadFrame] [width] [height]
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import SQDrawKit

let a = CommandLine.arguments
let out = a.count > 1 ? a[1] : "timeline-mac.png"
let frame = a.count > 2 ? Int(a[2]) ?? 0 : 420
let w = a.count > 3 ? Int(a[3]) ?? 960 : 960
let h = a.count > 4 ? Int(a[4]) ?? 300 : 300

let list = TimelineStrip.draw(width: w, height: h, playheadFrame: frame)
let space = CGColorSpaceCreateDeviceRGB()  // no color management: same numbers as the D3D12 back buffer
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setShouldAntialias(false)
ctx.translateBy(x: 0, y: CGFloat(h))
ctx.scaleBy(x: 1, y: -1)
for r in list.flattened() {
    ctx.setFillColor(red: CGFloat(r.color.r), green: CGFloat(r.color.g), blue: CGFloat(r.color.b), alpha: CGFloat(r.color.a))
    ctx.fill(CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h)))
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { print("write failed"); exit(1) }
print("wrote \(out): \(w)x\(h), playhead frame \(frame), \(list.flattened().count) rects")
#else
print("SQDrawMac needs CoreGraphics (Mac only)")
#endif
