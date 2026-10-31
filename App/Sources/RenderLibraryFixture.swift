import AppKit
import SQUIKit

/// The Library fixture of `render-panels.sh` (and the shared UI shot): Overlays pictures, SFX and Music sounds, B-Roll empty.
enum RenderLibraryFixture {
    @MainActor static func make(at root: URL) {
        try? FileManager.default.removeItem(at: root)
        let fm = FileManager.default
        func dir(_ n: String) -> URL { let u = root.appendingPathComponent(n); try? fm.createDirectory(at: u, withIntermediateDirectories: true); return u }
        let overlays = ["Dirt", "Fire", "Fog", "Green Screen", "Film Grain", "Light Leak", "Dust", "Bokeh", "Rain", "Flare", "Smoke", "Sparks"]
        for (i, n) in overlays.enumerated() {
            let size = 96
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size * 5 / 8, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            Theme.Palette.graphCurve[i % Theme.Palette.graphCurve.count].setFill()
            NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir("Overlays").appendingPathComponent("\(n).png"))
        }
        func wav(_ url: URL, samples: Int = 4410) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var d = Data("RIFF".utf8); func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
            let n = samples; u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
            d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2)); d.append(Data(count: n * 2)); try? d.write(to: url)
        }
        for n in ["Whoosh 01", "Whoosh 02", "Riser Short", "Click Soft", "Pop", "Camera Shutter", "Impact Low", "Swish Paper"] { wav(dir("SFX").appendingPathComponent("\(n).wav")) }
        // Music with categories (subfolders, one nested) as in the Library sections.
        let music = dir("Music")
        for n in ["Late Sun", "Open Road"] { wav(music.appendingPathComponent("\(n).wav"), samples: 44100 * 95) }
        for n in ["Morning Haze", "Slow Tide", "Paper Moon"] { wav(music.appendingPathComponent("Calm/\(n).wav"), samples: 44100 * 140) }
        for n in ["Keys One", "Keys Two"] { wav(music.appendingPathComponent("Calm/Piano/\(n).wav"), samples: 44100 * 75) }
        for n in ["Drive", "Rising Storm", "Final Push", "Anthem"] { wav(music.appendingPathComponent("Epic/\(n).wav"), samples: 44100 * 120) }
        for n in ["Tick Tock", "Lo-Fi Beat"] { wav(music.appendingPathComponent("Chill/\(n).wav"), samples: 44100 * 110) }
        _ = dir("B-Roll")
    }
}
