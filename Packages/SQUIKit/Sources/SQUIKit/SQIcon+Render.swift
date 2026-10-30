import AppKit
import SwiftUI

// Renders the bundled SVGs (24 grid, round caps and joins) as vector drawing handlers: crisp at 1x and 2x, template
// images tint through the usual contentTintColor / foregroundStyle. This file is the only code that reads icon files.

extension SQIcon {
    /// Template image at `size` points (square). Cached per icon and size.
    public func image(size: CGFloat = 16) -> NSImage {
        SQIconCache.shared.image(self, size: size)
    }

    /// Non-template image drawn in `color` (palette badges, cursors). Not cached.
    /// `stroke` is the line width on the 24 grid (nil: the optical default for `size`).
    public func image(size: CGFloat = 16, color: NSColor, stroke: CGFloat? = nil) -> NSImage {
        SQIconCache.shared.render(self, size: size, color: color, stroke: stroke)
    }

    /// SwiftUI accessor: a template image that follows `foregroundStyle`.
    public func swiftUIImage(size: CGFloat = 16) -> Image {
        Image(nsImage: image(size: size)).renderingMode(.template)
    }
}

struct SQIconShape: @unchecked Sendable {
    var path: CGPath
    var fill: Bool
    var stroke: Bool
}

final class SQIconCache: @unchecked Sendable {
    static let shared = SQIconCache()
    private let lock = NSLock()
    private var shapes: [SQIcon: [SQIconShape]] = [:]
    private var images: [String: NSImage] = [:]

    func image(_ icon: SQIcon, size: CGFloat) -> NSImage {
        let key = "\(icon.rawValue)@\(size)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = images[key] { return hit }
        let image = renderLocked(icon, size: size, color: nil, stroke: nil)
        images[key] = image
        return image
    }

    func render(_ icon: SQIcon, size: CGFloat, color: NSColor, stroke: CGFloat? = nil) -> NSImage {
        lock.lock()
        defer { lock.unlock() }
        return renderLocked(icon, size: size, color: color, stroke: stroke)
    }

    func parsed(_ icon: SQIcon) -> [SQIconShape] {
        lock.lock()
        defer { lock.unlock() }
        return shapesLocked(icon)
    }

    private func shapesLocked(_ icon: SQIcon) -> [SQIconShape] {
        if let hit = shapes[icon] { return hit }
        var result: [SQIconShape] = []
        if let url = Bundle.module.url(forResource: icon.resource, withExtension: "svg", subdirectory: "Icons"),
           let data = try? Data(contentsOf: url) {
            let parser = XMLParser(data: data)
            let delegate = SQIconSVGParser()
            parser.delegate = delegate
            parser.parse()
            result = delegate.shapes
        }
        shapes[icon] = result
        return result
    }

    private func renderLocked(_ icon: SQIcon, size: CGFloat, color: NSColor?, stroke: CGFloat?) -> NSImage {
        let shapes = shapesLocked(icon)
        let filled = icon.isFilled
        // Optical stroke: 1.6 on the 24 grid, thicker below 16 pt so lines stay one device pixel or more.
        let width = stroke ?? max(1.6, 22.8 / max(size, 1))
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = min(rect.width, rect.height) / 24
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            let tint = (color ?? NSColor.black).cgColor
            ctx.setStrokeColor(tint)
            ctx.setFillColor(tint)
            for shape in shapes {
                ctx.addPath(shape.path)
                if shape.fill || (filled && shape.stroke) {
                    ctx.drawPath(using: shape.stroke ? .fillStroke : .fill)
                } else if shape.stroke {
                    ctx.strokePath()
                } else {
                    ctx.beginPath()
                }
            }
            ctx.restoreGState()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

private final class SQIconSVGParser: NSObject, XMLParserDelegate {
    var shapes: [SQIconShape] = []

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String] = [:]) {
        func num(_ key: String) -> CGFloat { CGFloat(Double(a[key] ?? "") ?? 0) }
        let path = CGMutablePath()
        switch element {
        case "path":
            SQIconPathData.append(a["d"] ?? "", to: path)
        case "circle":
            let r = num("r")
            path.addEllipse(in: CGRect(x: num("cx") - r, y: num("cy") - r, width: 2 * r, height: 2 * r))
        case "ellipse":
            path.addEllipse(in: CGRect(x: num("cx") - num("rx"), y: num("cy") - num("ry"), width: 2 * num("rx"), height: 2 * num("ry")))
        case "rect":
            let rect = CGRect(x: num("x"), y: num("y"), width: num("width"), height: num("height"))
            var rx = a["rx"].flatMap { Double($0) }.map { CGFloat($0) }
            var ry = a["ry"].flatMap { Double($0) }.map { CGFloat($0) }
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cx = min(rx ?? 0, rect.width / 2), cy = min(ry ?? 0, rect.height / 2)
            if cx > 0 && cy > 0 {
                path.addRoundedRect(in: rect, cornerWidth: cx, cornerHeight: cy)
            } else {
                path.addRect(rect)
            }
        case "line":
            path.move(to: CGPoint(x: num("x1"), y: num("y1")))
            path.addLine(to: CGPoint(x: num("x2"), y: num("y2")))
        case "polyline", "polygon":
            let values = SQIconPathData.numbers(a["points"] ?? "")
            var i = 0
            while i + 1 < values.count {
                let p = CGPoint(x: values[i], y: values[i + 1])
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                i += 2
            }
            if element == "polygon" { path.closeSubpath() }
        default:
            return
        }
        let fillValue = a["fill"] ?? "none"
        shapes.append(SQIconShape(path: path, fill: fillValue != "none", stroke: (a["stroke"] ?? "currentColor") != "none"))
    }
}

extension CGMutablePath: SQIconPathSink {
    public func sinkMove(_ p: CGPoint) { move(to: p) }
    public func sinkLine(_ p: CGPoint) { addLine(to: p) }
    public func sinkCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint) { addCurve(to: p, control1: control1, control2: control2) }
    public func sinkQuad(to p: CGPoint, control: CGPoint) { addQuadCurve(to: p, control: control) }
    public func sinkClose() { closeSubpath() }
}
