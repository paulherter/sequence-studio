// Shared drawing layer (spike): scenes emit rectangles and text runs into a DrawList. No AppKit, no WinSDK,
// no Foundation: each platform only has to fill rectangles. Pixels, y down, colors 0...1.

public struct DrawColor: Sendable, Equatable {
    public var r, g, b, a: Float
    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
}

public struct DrawRect: Sendable, Equatable {
    public var x, y, w, h: Float
    public var color: DrawColor
    public init(x: Float, y: Float, w: Float, h: Float, color: DrawColor) { self.x = x; self.y = y; self.w = w; self.h = h; self.color = color }
}

public enum DrawCommand: Sendable, Equatable {
    case rect(DrawRect)
    /// Text run, top-left at (x, y). `scale` multiplies the 5x7 bitmap font.
    case text(x: Int, y: Int, string: String, scale: Int, color: DrawColor)
}

public struct DrawList: Sendable {
    public private(set) var commands: [DrawCommand] = []
    public init() {}

    public mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: DrawColor) {
        commands.append(.rect(DrawRect(x: Float(x), y: Float(y), w: Float(w), h: Float(h), color: color)))
    }
    public mutating func text(_ x: Int, _ y: Int, _ s: String, scale: Int = 2, _ color: DrawColor) {
        commands.append(.text(x: x, y: y, string: s, scale: scale, color: color))
    }

    /// Rectangles only: text runs are expanded through the baked bitmap font (one rect per horizontal pixel run).
    /// shortcut: no real glyph atlas or antialiasing; upgrade when the toolkit needs real fonts.
    public func flattened() -> [DrawRect] {
        var out: [DrawRect] = []
        for c in commands {
            switch c {
            case .rect(let r): out.append(r)
            case .text(let x, let y, let s, let scale, let color):
                var pen = x
                for ch in s {
                    let rows = BitmapFont.glyph(ch)
                    for (ry, bits) in rows.enumerated() {
                        var cx = 0
                        while cx < 5 {
                            if bits & (0x10 >> UInt8(cx)) != 0 {
                                var run = 1
                                while cx + run < 5, bits & (0x10 >> UInt8(cx + run)) != 0 { run += 1 }
                                out.append(DrawRect(x: Float(pen + cx * scale), y: Float(y + ry * scale),
                                                    w: Float(run * scale), h: Float(scale), color: color))
                                cx += run
                            } else { cx += 1 }
                        }
                    }
                    pen += 6 * scale
                }
            }
        }
        return out
    }
}
